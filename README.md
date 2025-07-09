# Cisco MAB to Nile Migration Tool

A web application that converts Cisco MAC address binding data to Nile segment authorization format. This tool allows users to upload a text file containing MAC address bindings from a Cisco switch, map VLANs to Nile segments, and generate a CSV file for import into Nile.

## Project Structure

- `frontend/`: Next.js web application
- `lambda/`: AWS Lambda function for processing the MAC address binding data

## Features

- Drag-and-drop interface for uploading MAC address binding files
- Automatic VLAN detection and mapping to Nile segments
- Optional Static IP Support checkbox to control IP-related columns in output
- CSV generation for import into Nile
- Responsive design
- Static deployment ready for Amazon S3 hosting


### Available Scripts

The project includes several npm scripts and shell scripts to make development and deployment easier:

- `npm install` - Install dependencies for the frontend
- `npm run build` - Build the frontend application
- `npm run deploy` - Deploy the application using the deploy.sh script
- `npm run deploy:cf` - Deploy the application using CloudFormation
- `./update.sh` - Update an already deployed application (incremental updates)

## Deployment to AWS

### CloudFormation Deployment (Recommended)

The easiest way to deploy the application is using the included CloudFormation deployment script:

1. Make the script executable:
   ```
   chmod +x deploy-cloudformation.sh
   ```

2. Run the deployment script:
   ```
   ./deploy-cloudformation.sh
   ```

The script will:
- Build the Next.js application
- Generate a unique S3 bucket name using a timestamp
- Deploy the CloudFormation stack
- Get the outputs from the stack (S3 bucket name and API Gateway endpoint)
- Update the API endpoint in the frontend code
- Rebuild the frontend with the updated API endpoint
- Upload the static site to the S3 bucket

Alternatively, you can deploy manually using the CloudFormation template:

1. Build the Next.js application:
   ```
   cd frontend
   npm install
   npm run build
   ```

2. Deploy the CloudFormation stack:
   ```
   aws cloudformation create-stack \
     --stack-name cisco-mab-to-nile \
     --template-body file://cloudformation.yaml \
     --capabilities CAPABILITY_IAM
   ```

3. Wait for the stack to be created:
   ```
   aws cloudformation wait stack-create-complete --stack-name cisco-mab-to-nile
   ```

4. Get the outputs from the stack:
   ```
   aws cloudformation describe-stacks --stack-name cisco-mab-to-nile --query "Stacks[0].Outputs"
   ```

5. Upload the static site to the S3 bucket (replace `your-bucket-name` with the actual bucket name from the outputs):
   ```
   aws s3 sync frontend/out/ s3://your-bucket-name
   ```

6. Update the API endpoint in the frontend code:
   ```
   echo "NEXT_PUBLIC_API_ENDPOINT=https://your-api-endpoint/process" > frontend/.env.production
   ```
   (Replace `https://your-api-endpoint/process` with the actual API endpoint from the outputs)

7. Rebuild and re-upload the frontend:
   ```
   cd frontend
   npm run build
   aws s3 sync out/ s3://your-bucket-name
   ```

### Script-based Deployment

This project includes a deployment script that automates the process of deploying the application to AWS S3 and Lambda:

1. Edit the configuration variables at the top of `deploy.sh` if needed:
   ```bash
   # The script automatically generates a unique bucket name with timestamp
   LAMBDA_FUNCTION_NAME="cisco-mab-to-nile"
   API_NAME="cisco-mab-to-nile-api"
   REGION="us-west-2"
   LAMBDA_ROLE_ARN="arn:aws:iam::your-account-id:role/lambda-execution-role"
   ```

2. Make the script executable:
   ```
   chmod +x deploy.sh
   ```

3. Run the deployment script:
   ```
   ./deploy.sh
   ```

The script will:
- Build and export the Next.js application as a static site
- Generate a unique S3 bucket name using a timestamp
- Create an S3 bucket and configure it for static website hosting
- Upload the static site to the S3 bucket
- Create or update the Lambda function
- Create or update the API Gateway
- Configure the API endpoint in the frontend application
- Re-deploy the frontend with the updated API endpoint

### Manual Deployment

If you prefer to deploy manually, follow these steps:

#### Frontend (S3 Static Website)

1. Build the Next.js application:
   ```
   cd frontend
   npm run build
   ```

2. The static site will be generated in the `out` directory (Next.js 13+).

3. Create an S3 bucket for hosting the static website:
   ```
   aws s3 mb s3://your-bucket-name
   ```

4. Configure the bucket for static website hosting:
   ```
   aws s3 website s3://your-bucket-name --index-document index.html --error-document 404.html
   ```

5. Set the bucket policy to allow public access:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Sid": "PublicReadGetObject",
         "Effect": "Allow",
         "Principal": "*",
         "Action": "s3:GetObject",
         "Resource": "arn:aws:s3:::your-bucket-name/*"
       }
     ]
   }
   ```

6. Upload the static site to the S3 bucket:
   ```
   aws s3 sync frontend/out/ s3://your-bucket-name
   ```

#### Lambda Function

1. Create a deployment package for the Lambda function:
   ```
   cd lambda
   zip -r function.zip lambda_function.py
   ```

2. Create the Lambda function:
   ```
   aws lambda create-function \
     --function-name cisco-mab-to-nile \
     --runtime python3.9 \
     --handler lambda_function.lambda_handler \
     --role arn:aws:iam::your-account-id:role/lambda-execution-role \
     --zip-file fileb://function.zip
   ```

#### API Gateway

1. Create an HTTP API:
   ```
   aws apigatewayv2 create-api \
     --name cisco-mab-to-nile-api \
     --protocol-type HTTP \
     --target arn:aws:lambda:region:your-account-id:function:cisco-mab-to-nile
   ```

2. Add necessary permissions for API Gateway to invoke the Lambda function:
   ```
   aws lambda add-permission \
     --function-name cisco-mab-to-nile \
     --statement-id apigateway-invoke \
     --action lambda:InvokeFunction \
     --principal apigateway.amazonaws.com \
     --source-arn "arn:aws:execute-api:region:your-account-id:api-id/*"
   ```

3. Update the frontend API endpoint in `.env.production` with the API Gateway URL.

## Updating an Existing Deployment

If you have already deployed the application and want to update it with code changes, use the update script instead of redeploying everything:

### Using the Update Script

1. Make the script executable (if not already done):
   ```
   chmod +x update.sh
   ```

2. Run the update script with your existing S3 bucket name:
   ```
   ./update.sh --bucket your-existing-bucket-name
   ```

   Or you can specify additional options:
   ```
   ./update.sh --bucket your-bucket-name --region us-west-2 --function cisco-mab-to-nile
   ```

3. The script will:
   - Verify that your existing resources (S3 bucket, Lambda function, API Gateway) exist
   - Update the Lambda function with the latest code
   - Rebuild the frontend with the correct API endpoint
   - Upload the updated frontend to S3
   - Provide you with the updated URLs

### Update Script Options

- `-b, --bucket BUCKET_NAME`: Specify the S3 bucket name (required)
- `-r, --region REGION`: Specify the AWS region (default: us-west-2)
- `-f, --function FUNCTION`: Specify the Lambda function name (default: cisco-mab-to-nile)
- `-a, --api API_NAME`: Specify the API Gateway name (default: cisco-mab-to-nile-api)
- `-h, --help`: Show help message

### When to Use the Update Script

Use the update script when you have made changes to:
- Lambda function code (`lambda/lambda_function.py`)
- Frontend code (any files in `frontend/`)
- Configuration or styling

The update script is faster than a full deployment because it doesn't recreate AWS resources, it only updates the code.

## Usage

1. Open the deployed website in a web browser.
2. Drag and drop a MAC address binding file or click to select a file.
3. Enter segment names for each VLAN detected in the file.
4. **Optional**: Check the "Static IP Support" checkbox if you need the IP-related columns in your CSV output:
   - When **unchecked** (default): CSV contains 8 columns (excludes Static IP, IP Address, and Passive IP columns)
   - When **checked**: CSV contains all 11 columns (includes the 3 IP-related columns)
5. Click "Process File" to generate the CSV.
6. Download the CSV file for import into Nile.

### Static IP Support Feature

The application includes a "Static IP Support" checkbox that controls whether IP-related columns are included in the generated CSV:

- **Default behavior (unchecked)**: The CSV will contain only the essential 8 columns, which is recommended for most use cases
- **When enabled (checked)**: The CSV will include all 11 columns, adding:
  - Static IP (Optional)
  - IP Address (Optional) 
  - Passive IP (Optional)

This feature allows you to generate cleaner CSV files when IP configuration is not needed, while still providing the option to include these columns when required.

## Input File Format

The tool expects a text file with MAC address bindings in the following format:

```
   1    001e.0b41.7afd    DYNAMIC     Gi1/0/15
   1    0023.7dc2.fddc    DYNAMIC     Gi1/0/24
   5    000a.f70e.af2f    DYNAMIC     Gi1/0/11
   5    047c.162d.2ef6    DYNAMIC     Gi1/0/16
```

Each line contains:
1. VLAN ID
2. MAC address
3. Type (e.g., DYNAMIC)
4. Port (e.g., Gi1/0/15)

## Output CSV Format

The tool generates a CSV file with the following columns:

**Base columns (when Static IP Support is disabled):**
1. MAC Address (Required)
2. Segment (Required for allow state)
3. Lock to Port (Optional)
4. Site (Optional)
5. Building (Optional)
6. Floor (Optional)
7. Allow or Deny (Required)

**Full columns (when Static IP Support is enabled):**
1. MAC Address (Required)
2. Segment (Required for allow state)
3. Lock to Port (Optional)
4. Site (Optional)
5. Building (Optional)
6. Floor (Optional)
7. Allow or Deny (Required)
8. Description (Optional)
9. Static IP (Optional)
10. IP Address (Optional)
11. Passive IP (Optional)

**Note:** When Static IP Support is disabled, the Description column and IP-related columns are omitted to create a cleaner CSV without trailing commas.

## License

This project is based on [migrate-meraki2nile](https://github.com/austinhawthorne/migrate-meraki2nile).
