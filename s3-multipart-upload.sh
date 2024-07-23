#!/bin/sh

# Resources
# https://awscli.amazonaws.com/v2/documentation/api/latest/reference/s3api/create-multipart-upload.html

# TODO
# - add hash check --content-md5
# - split file before uploafing to shorten session time
# - add retry on fail instead of exist. Maybe an option to resume 

# Function to display usage information
usage() {
  echo "Usage: $0 -f <file> -b <bucket> -d <destination> [-p <profile>]"
  echo "  -f: File to upload including path to the file"
  echo "  -b: S3 bucket name"
  echo "  -d: Destination (this will form part of the key)"
  echo "  -p: AWS CLI profile (optional)"
  exit 1
}

# Function to display progress bar
progress_bar() {
  local current=$1
  local total=$2
  local width=50
  local percentage=$((current * 100 / total))
  local completed=$((width * current / total))
  local remaining=$((width - completed))
  printf "\r[%-${width}s] %d%%" "$(printf '#%.0s' $(seq 1 $completed))$(printf ' %.0s' $(seq 1 $remaining))" "$percentage"
}

# Parse command line arguments
while getopts ":f:b:d:p:" opt; do
  case $opt in
    f) file="$OPTARG" ;;
    b) bucket="$OPTARG" ;;
    d) destination="$OPTARG" ;;
    p) profile="$OPTARG" ;;
    \?) echo "Invalid option -$OPTARG" >&2; usage ;;
    :) echo "Option -$OPTARG requires an argument" >&2; usage ;;
  esac
done

# Check if required arguments are provided
if [ -z "$file" ] || [ -z "$bucket" ] || [ -z "$destination" ]; then
  echo "Error: Missing required arguments"
  usage
fi

# Check if file exists
if [ ! -f "$file" ]; then
  echo "Error: File '$file' not found"
  exit 1
fi

# Construct the S3 key
filename=$(basename "$file")
key="${destination%/}/${filename}"

# Set AWS CLI command prefix based on profile
if [ -n "$profile" ]; then
  aws_cmd="aws --profile $profile"
else
  aws_cmd="aws"
fi

# Start multipart upload
upload_id=$($aws_cmd s3api create-multipart-upload --bucket "$bucket" --key "$key" --query 'UploadId' --output text)

if [ -z "$upload_id" ]; then
  echo "Error: Failed to initiate multipart upload"
  exit 1
fi
 
echo "Multipart upload initiated. Upload ID: $upload_id"

# Calculate optimal part size (minimum 5MB)
file_size=$(stat -f %z "$file")
part_size=$((file_size / 1000 + 5000000))  # Divide into roughly 1000 parts, but ensure at least 5MB
if [ $part_size -lt 5000000 ]; then
  part_size=5000000
fi

# Create a temporary file
temp_file=$(mktemp)

# Upload parts
part_number=1
offset=0
total_parts=$((file_size / part_size + (file_size % part_size > 0)))

echo "Uploading file: $file"
echo "Total file size: $file_size bytes"
echo "Part size: $part_size bytes"
echo "Total parts: $total_parts"

while [ $offset -lt $file_size ]; do
  end=$((offset + part_size - 1))
  if [ $end -ge $file_size ]; then
    end=$((file_size - 1))
  fi
  
  printf "Copty to temp part %d/%d: " "$part_number" "$total_parts"
  time (
    dd if="$file" bs=1 skip=$offset count=$((end - offset + 1)) of="$temp_file" 2>/dev/null
  )
  printf "Uploading part %d/%d: " "$part_number" "$total_parts"
  time (
    etag=$($aws_cmd s3api upload-part --bucket "$bucket" --key "$key" --part-number $part_number --upload-id "$upload_id" --body "$temp_file" --query 'ETag' --output text)
  )
  if [ -z "$etag" ]; then
    echo "Error: Failed to upload part $part_number"
    $aws_cmd s3api abort-multipart-upload --bucket "$bucket" --key "$key" --upload-id "$upload_id"
    rm -f "$temp_file"
    exit 1
  fi
  
  echo "Done. ETag: $etag"
  parts="$parts {\"PartNumber\": $part_number, \"ETag\": $etag},"
  
  offset=$((offset + part_size))
  part_number=$((part_number + 1))
  
  progress_bar $((part_number - 1)) $total_parts
done

echo  # New line after progress bar

# Remove trailing comma from parts list
parts=${parts%,}

# Complete multipart upload
echo "Completing multipart upload..."
$aws_cmd s3api complete-multipart-upload --bucket "$bucket" --key "$key" --upload-id "$upload_id" \
  --multipart-upload "{\"Parts\": [$parts]}"

# Clean up
rm -f "$temp_file"

echo "Upload completed successfully"