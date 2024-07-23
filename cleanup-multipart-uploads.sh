#!/bin/bash

BUCKET_NAME="synctech-prod-assets"
profile="synctech-platform-au-prod"

# Set AWS CLI command prefix based on profile
if [ -n "$profile" ]; then
  aws_cmd="aws --profile $profile"
else
  aws_cmd="aws"
fi

# List all multipart uploads and extract upload IDs and keys
uploads=$($aws_cmd s3api list-multipart-uploads --bucket $BUCKET_NAME --query 'Uploads[*].[UploadId, Key]' --output text)

# Abort each multipart upload
while read -r upload_id key; do
    echo "Aborting upload for key: $key"
    $aws_cmd s3api abort-multipart-upload --bucket $BUCKET_NAME --key "$key" --upload-id "$upload_id"
done <<< "$uploads"

echo "All incomplete multipart uploads have been aborted."