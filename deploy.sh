#!/bin/bash

# Cisco MAB to Nile Migration Tool Deployment Script
# This script deploys the application to AWS S3 and Lambda

# Configuration
# Generate a unique bucket name with timestamp
TIMESTAMP=$(date +%Y%m%d%H%M%S)
BUCKET_NAME="treagan-nile-mab-cisco-migration-${TIMESTAMP}"
LAMBDA_FUNCTION_NAME="cisco-mab-to-nile"
API_NAME="cisco-mab-to-nile-api"
REGION="us-west-2"
LAMBDA_ROLE_ARN="arn:aws:iam::your-account-id:role/lambda-execution-role"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    echo -e "${RED}AWS CLI is not installed. Please install it first.${NC}"
    exit 1
fi

# Check if AWS CLI is configured
if ! aws sts get-caller-identity &> /dev/null; then
    echo -e "${RED}AWS CLI is not configured. Please run 'aws configure' first.${NC}"
    exit 1
fi

echo -e "${YELLOW}Starting deployment of Cisco MAB to Nile Migration Tool...${NC}"

# Build and export the Next.js application
echo -e "${YELLOW}Building the Next.js application...${NC}"
cd frontend
npm install
npm run build

# Check if next export is available
if grep -q "next export" package.json; then
    echo -e "${YELLOW}Exporting static site...${NC}"
    npx next export
    EXPORT_DIR="out"
else
    echo -e "${YELLOW}Using standalone output...${NC}"
    EXPORT_DIR=".next/standalone"
fi

# Check if S3 bucket exists
echo -e "${YELLOW}Checking if S3 bucket exists...${NC}"
if aws s3api head-bucket --bucket $BUCKET_NAME --region $REGION 2>/dev/null; then
    echo -e "${YELLOW}S3 bucket already exists: $BUCKET_NAME${NC}"
    echo -e "${YELLOW}Emptying bucket before update...${NC}"
    aws s3 rm s3://$BUCKET_NAME --recursive --region $REGION
else
    echo -e "${YELLOW}Creating S3 bucket: $BUCKET_NAME${NC}"
    aws s3 mb s3://$BUCKET_NAME --region $REGION
    
    # Configure bucket ownership controls
    echo -e "${YELLOW}Configuring bucket ownership controls...${NC}"
    aws s3api put-bucket-ownership-controls \
        --bucket $BUCKET_NAME \
        --ownership-controls="Rules=[{ObjectOwnership=ObjectWriter}]" \
        --region $REGION

    # Configure public access block settings
    echo -e "${YELLOW}Configuring public access block settings...${NC}"
    aws s3api put-public-access-block \
        --bucket $BUCKET_NAME \
        --public-access-block-configuration "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false" \
        --region $REGION

    # Configure bucket for static website hosting
    echo -e "${YELLOW}Configuring bucket for static website hosting...${NC}"
    aws s3 website s3://$BUCKET_NAME --index-document index.html --error-document 404.html --region $REGION
    
    # Set bucket policy to allow public access
    echo -e "${YELLOW}Setting bucket policy to allow public access...${NC}"
    cat > /tmp/bucket-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "PublicReadGetObject",
      "Effect": "Allow",
      "Principal": "*",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::$BUCKET_NAME/*"
    }
  ]
}
EOF
    aws s3api put-bucket-policy --bucket $BUCKET_NAME --policy file:///tmp/bucket-policy.json --region $REGION
fi

# Wait for the bucket to be available
echo -e "${YELLOW}Waiting for the S3 bucket to be available...${NC}"
MAX_RETRIES=10
RETRY_COUNT=0
BUCKET_AVAILABLE=false

while [ $RETRY_COUNT -lt $MAX_RETRIES ] && [ "$BUCKET_AVAILABLE" = false ]; do
    if aws s3api head-bucket --bucket $BUCKET_NAME --region $REGION 2>/dev/null; then
        BUCKET_AVAILABLE=true
        echo -e "${GREEN}S3 bucket is now available.${NC}"
    else
        RETRY_COUNT=$((RETRY_COUNT+1))
        echo -e "${YELLOW}Waiting for S3 bucket to be available... (Attempt $RETRY_COUNT/$MAX_RETRIES)${NC}"
        sleep 10
    fi
done

if [ "$BUCKET_AVAILABLE" = false ]; then
    echo -e "${RED}S3 bucket did not become available after $MAX_RETRIES attempts.${NC}"
    exit 1
fi

# Upload the static site to the S3 bucket
echo -e "${YELLOW}Uploading the static site to the S3 bucket...${NC}"
aws s3 sync $EXPORT_DIR/ s3://$BUCKET_NAME --delete --region $REGION

# Create Lambda deployment package
echo -e "${YELLOW}Creating Lambda deployment package...${NC}"
cd ../lambda
# Create a temporary directory for the Lambda package
mkdir -p lambda_package
cp lambda_function.py lambda_package/
cd lambda_package
zip -r ../function.zip .
cd ..
rm -rf lambda_package

# Check if Lambda function exists
echo -e "${YELLOW}Checking if Lambda function exists...${NC}"
if aws lambda get-function --function-name $LAMBDA_FUNCTION_NAME &>/dev/null; then
    # Update existing Lambda function
    echo -e "${YELLOW}Updating existing Lambda function...${NC}"
    aws lambda update-function-code \
        --function-name $LAMBDA_FUNCTION_NAME \
        --zip-file fileb://function.zip \
        --region $REGION
    
    # Wait for the function update to complete
    echo -e "${YELLOW}Waiting for Lambda function update to complete...${NC}"
    aws lambda wait function-updated \
        --function-name $LAMBDA_FUNCTION_NAME \
        --region $REGION
    
    echo -e "${GREEN}Lambda function updated successfully.${NC}"
else
    # Create new Lambda function
    echo -e "${YELLOW}Creating new Lambda function...${NC}"
    aws lambda create-function \
        --function-name $LAMBDA_FUNCTION_NAME \
        --runtime python3.9 \
        --handler lambda_function.lambda_handler \
        --role $LAMBDA_ROLE_ARN \
        --zip-file fileb://function.zip \
        --region $REGION
fi

# Check if API Gateway exists
echo -e "${YELLOW}Checking if API Gateway exists...${NC}"
API_ID=$(aws apigatewayv2 get-apis --query "Items[?Name=='$API_NAME'].ApiId" --output text --region $REGION)

if [ -z "$API_ID" ]; then
    # Create new API Gateway
    echo -e "${YELLOW}Creating new API Gateway...${NC}"
    API_RESULT=$(aws apigatewayv2 create-api \
        --name $API_NAME \
        --protocol-type HTTP \
        --target arn:aws:lambda:$REGION:$(aws sts get-caller-identity --query Account --output text):function:$LAMBDA_FUNCTION_NAME \
        --region $REGION)
    
    API_ID=$(echo $API_RESULT | jq -r '.ApiId')
    
    # Add permission for API Gateway to invoke Lambda
    echo -e "${YELLOW}Adding permission for API Gateway to invoke Lambda...${NC}"
    aws lambda add-permission \
        --function-name $LAMBDA_FUNCTION_NAME \
        --statement-id apigateway-invoke \
        --action lambda:InvokeFunction \
        --principal apigateway.amazonaws.com \
        --source-arn "arn:aws:execute-api:$REGION:$(aws sts get-caller-identity --query Account --output text):$API_ID/*" \
        --region $REGION
else
    echo -e "${YELLOW}API Gateway already exists with ID: $API_ID${NC}"
fi

# Get the API Gateway URL
API_URL=$(aws apigatewayv2 get-api --api-id $API_ID --query "ApiEndpoint" --output text --region $REGION)
API_ENDPOINT="${API_URL}/process"

# Create .env files with API endpoint
echo -e "${YELLOW}Creating .env files with API endpoint...${NC}"
cat > frontend/.env.production << EOF
NEXT_PUBLIC_API_ENDPOINT=${API_ENDPOINT}
EOF

# Also update .env.local for local development
cat > frontend/.env.local << EOF
NEXT_PUBLIC_API_ENDPOINT=${API_ENDPOINT}
EOF

echo -e "${YELLOW}API endpoint set to: ${API_ENDPOINT}${NC}"

# Rebuild the frontend with the updated API endpoint
echo -e "${YELLOW}Rebuilding frontend with updated API endpoint...${NC}"
cd frontend
npm run build
cd ..

# Re-upload the static site to the S3 bucket
echo -e "${YELLOW}Re-uploading the static site to the S3 bucket...${NC}"
aws s3 sync frontend/$EXPORT_DIR/ s3://$BUCKET_NAME --delete --region $REGION

echo -e "${GREEN}Deployment completed successfully!${NC}"
echo -e "${GREEN}Frontend URL: http://$BUCKET_NAME.s3-website-$REGION.amazonaws.com${NC}"
echo -e "${GREEN}API Gateway URL: ${API_ENDPOINT}${NC}"

# Return to the project root
cd ..

echo -e "${YELLOW}To test the application locally, run:${NC}"
echo -e "${GREEN}cd frontend && npm run dev${NC}"
