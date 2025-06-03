#!/bin/bash

# Cisco MAB to Nile Migration Tool CloudFormation Deployment Script
# This script deploys the application using CloudFormation

# Configuration
STACK_NAME="cisco-mab-to-nile"
REGION="us-west-2"
# Generate a unique bucket name with timestamp
TIMESTAMP=$(date +%Y%m%d%H%M%S)
BUCKET_NAME_PARAM="nile-mab-cisco-migration-${TIMESTAMP}"

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

echo -e "${YELLOW}Starting deployment of Cisco MAB to Nile Migration Tool using CloudFormation...${NC}"

# Build and export the Next.js application
echo -e "${YELLOW}Building the Next.js application...${NC}"
cd frontend
npm install
npm run build

# Check if the stack already exists
STACK_EXISTS=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --region $REGION 2>/dev/null || echo "STACK_NOT_FOUND")

if [[ $STACK_EXISTS != "STACK_NOT_FOUND" ]]; then
  # Get the current bucket name from the stack
  CURRENT_BUCKET=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --query "Stacks[0].Outputs[?OutputKey=='BucketName'].OutputValue" --output text --region $REGION)
  
  if [[ ! -z "$CURRENT_BUCKET" ]]; then
    echo -e "${YELLOW}Existing bucket found: ${CURRENT_BUCKET}${NC}"
    echo -e "${YELLOW}Emptying bucket before update...${NC}"
    aws s3 rm s3://$CURRENT_BUCKET --recursive --region $REGION
    
    # Use the existing bucket name instead of creating a new one
    BUCKET_NAME_PARAM=$CURRENT_BUCKET
    echo -e "${YELLOW}Using existing bucket: ${BUCKET_NAME_PARAM}${NC}"
  fi
fi

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

# Upload Lambda function to S3 bucket
echo -e "${YELLOW}Uploading Lambda function to S3 bucket...${NC}"
if aws s3api head-bucket --bucket $BUCKET_NAME_PARAM --region $REGION 2>/dev/null; then
    echo -e "${YELLOW}Uploading Lambda function to S3 bucket: $BUCKET_NAME_PARAM${NC}"
    aws s3 cp function.zip s3://$BUCKET_NAME_PARAM/function.zip --region $REGION
else
    echo -e "${YELLOW}Creating temporary S3 bucket for Lambda function...${NC}"
    TEMP_BUCKET="temp-lambda-bucket-${TIMESTAMP}"
    aws s3 mb s3://$TEMP_BUCKET --region $REGION
    aws s3 cp function.zip s3://$TEMP_BUCKET/function.zip --region $REGION
    BUCKET_NAME_PARAM=$TEMP_BUCKET
fi

# Check if the stack already exists and update the Lambda function directly
if [[ $STACK_EXISTS != "STACK_NOT_FOUND" ]]; then
    # Get the Lambda function name from the stack
    LAMBDA_FUNCTION_NAME=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --query "Stacks[0].Outputs[?OutputKey=='LambdaFunctionName'].OutputValue" --output text --region $REGION)
    
    if [[ ! -z "$LAMBDA_FUNCTION_NAME" ]]; then
        echo -e "${YELLOW}Updating Lambda function code directly: ${LAMBDA_FUNCTION_NAME}${NC}"
        aws lambda update-function-code \
            --function-name $LAMBDA_FUNCTION_NAME \
            --s3-bucket $BUCKET_NAME_PARAM \
            --s3-key function.zip \
            --region $REGION
    fi
fi

cd ../frontend

# Deploy the CloudFormation stack
echo -e "${YELLOW}Deploying CloudFormation stack...${NC}"
aws cloudformation deploy \
  --stack-name $STACK_NAME \
  --template-file ../cloudformation.yaml \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides BucketName=$BUCKET_NAME_PARAM \
  --region $REGION

# Check if the deployment was successful
if [ $? -ne 0 ]; then
    echo -e "${RED}CloudFormation stack deployment failed.${NC}"
    exit 1
fi

# Get the outputs from the stack
echo -e "${YELLOW}Getting outputs from the CloudFormation stack...${NC}"
OUTPUTS=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --query "Stacks[0].Outputs" --output json --region $REGION)

# Extract the bucket name and API endpoint
BUCKET_NAME=$(echo $OUTPUTS | jq -r '.[] | select(.OutputKey=="BucketName") | .OutputValue')
API_ENDPOINT=$(echo $OUTPUTS | jq -r '.[] | select(.OutputKey=="ApiEndpoint") | .OutputValue')

echo -e "${YELLOW}Bucket name: ${BUCKET_NAME}${NC}"
echo -e "${YELLOW}API endpoint: ${API_ENDPOINT}${NC}"

# Create .env.production file with API endpoint
echo -e "${YELLOW}Creating .env.production file with API endpoint...${NC}"
echo "NEXT_PUBLIC_API_ENDPOINT=${API_ENDPOINT}" > .env.production

# Also update .env.local for local development
echo -e "${YELLOW}Updating .env.local for local development...${NC}"
echo "NEXT_PUBLIC_API_ENDPOINT=${API_ENDPOINT}" > .env.local

echo -e "${YELLOW}API endpoint set to: ${API_ENDPOINT}${NC}"

# Rebuild the frontend with the updated API endpoint
echo -e "${YELLOW}Rebuilding frontend with updated API endpoint...${NC}"
npm run build

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
    echo -e "${YELLOW}Creating the bucket manually...${NC}"
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

# Upload the static site to the S3 bucket
echo -e "${YELLOW}Uploading the static site to the S3 bucket...${NC}"
aws s3 sync out/ s3://$BUCKET_NAME --delete --region $REGION

echo -e "${GREEN}Deployment completed successfully!${NC}"
echo -e "${GREEN}Frontend URL: http://${BUCKET_NAME}.s3-website-${REGION}.amazonaws.com${NC}"
echo -e "${GREEN}API Gateway URL: ${API_ENDPOINT}${NC}"

# Return to the project root
cd ..

echo -e "${YELLOW}To test the application locally, run:${NC}"
echo -e "${GREEN}cd frontend && npm run dev${NC}"
