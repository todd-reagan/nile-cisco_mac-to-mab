#!/bin/bash

# Cisco MAB to Nile Migration Tool Update Script
# This script updates an already deployed application (Lambda function and S3 static site)

# Configuration - Update these values to match your deployed resources
BUCKET_NAME=""  # Set this to your existing S3 bucket name
LAMBDA_FUNCTION_NAME="cisco-mab-to-nile"
API_NAME="cisco-mab-to-nile-api"
REGION="us-west-2"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print usage
print_usage() {
    echo -e "${BLUE}Usage: $0 [OPTIONS]${NC}"
    echo -e "${BLUE}Options:${NC}"
    echo -e "  -b, --bucket BUCKET_NAME    Specify the S3 bucket name"
    echo -e "  -r, --region REGION         Specify the AWS region (default: us-west-2)"
    echo -e "  -f, --function FUNCTION     Specify the Lambda function name (default: cisco-mab-to-nile)"
    echo -e "  -a, --api API_NAME          Specify the API Gateway name (default: cisco-mab-to-nile-api)"
    echo -e "  -h, --help                  Show this help message"
    echo -e ""
    echo -e "${BLUE}Example:${NC}"
    echo -e "  $0 --bucket my-bucket-name-20241209120000"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -b|--bucket)
            BUCKET_NAME="$2"
            shift 2
            ;;
        -r|--region)
            REGION="$2"
            shift 2
            ;;
        -f|--function)
            LAMBDA_FUNCTION_NAME="$2"
            shift 2
            ;;
        -a|--api)
            API_NAME="$2"
            shift 2
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            print_usage
            exit 1
            ;;
    esac
done

# Check if bucket name is provided
if [ -z "$BUCKET_NAME" ]; then
    echo -e "${RED}Error: S3 bucket name is required.${NC}"
    echo -e "${YELLOW}You can specify it using: $0 --bucket YOUR_BUCKET_NAME${NC}"
    echo -e "${YELLOW}Or edit the script and set BUCKET_NAME variable.${NC}"
    exit 1
fi

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

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Cisco MAB to Nile Migration Tool${NC}"
echo -e "${BLUE}         Update Script${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "${YELLOW}Bucket: $BUCKET_NAME${NC}"
echo -e "${YELLOW}Region: $REGION${NC}"
echo -e "${YELLOW}Lambda: $LAMBDA_FUNCTION_NAME${NC}"
echo -e "${YELLOW}API: $API_NAME${NC}"
echo -e "${BLUE}========================================${NC}"

# Verify that the S3 bucket exists
echo -e "${YELLOW}Verifying S3 bucket exists...${NC}"
if ! aws s3api head-bucket --bucket $BUCKET_NAME --region $REGION 2>/dev/null; then
    echo -e "${RED}Error: S3 bucket '$BUCKET_NAME' does not exist or is not accessible.${NC}"
    exit 1
fi
echo -e "${GREEN}✓ S3 bucket verified${NC}"

# Verify that the Lambda function exists
echo -e "${YELLOW}Verifying Lambda function exists...${NC}"
if ! aws lambda get-function --function-name $LAMBDA_FUNCTION_NAME --region $REGION &>/dev/null; then
    echo -e "${RED}Error: Lambda function '$LAMBDA_FUNCTION_NAME' does not exist.${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Lambda function verified${NC}"

# Get the API Gateway ID and endpoint
echo -e "${YELLOW}Getting API Gateway information...${NC}"
API_ID=$(aws apigatewayv2 get-apis --query "Items[?Name=='$API_NAME'].ApiId" --output text --region $REGION)
if [ -z "$API_ID" ] || [ "$API_ID" = "None" ]; then
    echo -e "${RED}Error: API Gateway '$API_NAME' not found.${NC}"
    exit 1
fi

API_URL=$(aws apigatewayv2 get-api --api-id $API_ID --query "ApiEndpoint" --output text --region $REGION)
API_ENDPOINT="${API_URL}/process"
echo -e "${GREEN}✓ API Gateway found: ${API_ENDPOINT}${NC}"

# Update Lambda function
echo -e "${YELLOW}Updating Lambda function...${NC}"
cd lambda

# Create Lambda deployment package
mkdir -p lambda_package
cp lambda_function.py lambda_package/
cd lambda_package
zip -r ../function.zip .
cd ..
rm -rf lambda_package

# Update the Lambda function code
aws lambda update-function-code \
    --function-name $LAMBDA_FUNCTION_NAME \
    --zip-file fileb://function.zip \
    --region $REGION

# Wait for the function update to complete
echo -e "${YELLOW}Waiting for Lambda function update to complete...${NC}"
aws lambda wait function-updated \
    --function-name $LAMBDA_FUNCTION_NAME \
    --region $REGION

echo -e "${GREEN}✓ Lambda function updated successfully${NC}"

# Clean up Lambda package
rm -f function.zip

# Update frontend
echo -e "${YELLOW}Building updated frontend...${NC}"
cd ../frontend

# Install dependencies
npm install

# Create/update .env files with API endpoint
echo -e "${YELLOW}Updating environment configuration...${NC}"
cat > .env.production << EOF
NEXT_PUBLIC_API_ENDPOINT=${API_ENDPOINT}
EOF

cat > .env.local << EOF
NEXT_PUBLIC_API_ENDPOINT=${API_ENDPOINT}
EOF

# Build the frontend
npm run build

# Determine export directory
if grep -q "next export" package.json; then
    echo -e "${YELLOW}Exporting static site...${NC}"
    npx next export
    EXPORT_DIR="out"
else
    echo -e "${YELLOW}Using build output...${NC}"
    EXPORT_DIR="out"
fi

echo -e "${GREEN}✓ Frontend built successfully${NC}"

# Update S3 bucket with new frontend
echo -e "${YELLOW}Uploading updated frontend to S3...${NC}"
aws s3 sync $EXPORT_DIR/ s3://$BUCKET_NAME --delete --region $REGION

echo -e "${GREEN}✓ Frontend uploaded successfully${NC}"

# Return to project root
cd ..

# Get the S3 website URL
WEBSITE_URL="http://$BUCKET_NAME.s3-website-$REGION.amazonaws.com"

echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}Update completed successfully!${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}Frontend URL: ${WEBSITE_URL}${NC}"
echo -e "${GREEN}API Gateway URL: ${API_ENDPOINT}${NC}"
echo -e "${BLUE}========================================${NC}"

echo -e "${YELLOW}Changes deployed:${NC}"
echo -e "  • Lambda function code updated"
echo -e "  • Frontend rebuilt and uploaded"
echo -e "  • Environment configuration updated"
echo -e ""
echo -e "${YELLOW}To test the application locally, run:${NC}"
echo -e "${GREEN}cd frontend && npm run dev${NC}"
