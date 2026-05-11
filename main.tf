# Main Terraform Configuration for S3 Scheduled Backups
# This file defines all the infrastructure resources needed for automated S3 backups

# Get current AWS account ID and region
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Generate random suffix for globally unique bucket names
resource "random_string" "bucket_suffix" {
  length  = 8
  special = false
  upper   = false
}

# Local values for consistent naming
locals {
  bucket_suffix = random_string.bucket_suffix.result
  common_tags = merge(
    var.tags,
    {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  )
  
  # Generate bucket names if not provided
  primary_bucket_name = var.primary_bucket_name != "" ? var.primary_bucket_name : "${var.project_name}-primary-${local.bucket_suffix}"
  backup_bucket_name  = var.backup_bucket_name != "" ? var.backup_bucket_name : "${var.project_name}-backup-${local.bucket_suffix}"
}

# =====================================================
# S3 BUCKETS
# =====================================================

# Primary S3 bucket for working data
resource "aws_s3_bucket" "primary" {
  bucket = local.primary_bucket_name
  tags   = local.common_tags
}

# Backup S3 bucket for protected data
resource "aws_s3_bucket" "backup" {
  bucket = local.backup_bucket_name
  tags   = local.common_tags
}

resource "aws_s3_bucket" "secondary_backup" {
  provider = aws.backup_region  # <--- Crucial line
  bucket   = "my-secondary-backup-bucket-name"
}


# Configure versioning for backup bucket
resource "aws_s3_bucket_versioning" "backup" {
  bucket = aws_s3_bucket.backup.id
  versioning_configuration {
    status = var.enable_versioning ? "Enabled" : "Disabled"
  }
}

# Server-side encryption for primary bucket
resource "aws_s3_bucket_server_side_encryption_configuration" "primary" {
  count  = var.enable_encryption ? 1 : 0
  bucket = aws_s3_bucket.primary.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# Server-side encryption for backup bucket
resource "aws_s3_bucket_server_side_encryption_configuration" "backup" {
  count  = var.enable_encryption ? 1 : 0
  bucket = aws_s3_bucket.backup.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# Block public access for primary bucket
resource "aws_s3_bucket_public_access_block" "primary" {
  bucket = aws_s3_bucket.primary.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Block public access for backup bucket
resource "aws_s3_bucket_public_access_block" "backup" {
  bucket = aws_s3_bucket.backup.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Lifecycle configuration for backup bucket
resource "aws_s3_bucket_lifecycle_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id

  rule {
    id     = "BackupRetentionRule"
    status = "Enabled"
    filter {
      
    }

    # Transition to Standard-IA after specified days
    dynamic "transition" {
      for_each = var.lifecycle_ia_transition_days > 0 ? [1] : []
      content {
        days          = var.lifecycle_ia_transition_days
        storage_class = "STANDARD_IA"
      }
    }

    # Transition to Glacier after specified days
    dynamic "transition" {
      for_each = var.lifecycle_glacier_transition_days > 0 ? [1] : []
      content {
        days          = var.lifecycle_glacier_transition_days
        storage_class = "GLACIER"
      }
    }

    # Expire objects after specified days
    dynamic "expiration" {
      for_each = var.lifecycle_expiration_days > 0 ? [1] : []
      content {
        days = var.lifecycle_expiration_days
      }
    }

    # Expire non-current versions after 30 days
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

# =====================================================
# IAM ROLE AND POLICY FOR LAMBDA
# =====================================================

# IAM role for Lambda function
resource "aws_iam_role" "lambda_backup_role" {
  name = "${var.project_name}-lambda-backup-role-${local.bucket_suffix}"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Sid    = ""
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
  
  tags = local.common_tags
}

# IAM policy for Lambda function
resource "aws_iam_role_policy" "lambda_backup_policy" {
  name = "${var.project_name}-lambda-backup-policy"
  role = aws_iam_role.lambda_backup_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.primary.arn,
          "${aws_s3_bucket.primary.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.backup.arn,
          "${aws_s3_bucket.backup.arn}/*",
           aws_s3_bucket.secondary_backup.arn,
          "${aws_s3_bucket.secondary_backup.arn}/*"
        ]
      }
    ]
  })
}

#====================================================
# SNS TOPIC FOR NOTIFICATIONS (OPTIONAL)
#====================================================
# Create the SNS Topic
resource "aws_sns_topic" "backup_notifications" {
  name = "${var.project_name}-backup-notifications-${local.bucket_suffix}"
  tags = local.common_tags
}

# Subscribe your email (Manual confirmation required in inbox)
resource "aws_sns_topic_subscription" "email_target" {
  topic_arn = aws_sns_topic.backup_notifications.arn
  protocol  = "email"
  endpoint  = "maheshkhatana1210@gmail.com" # Change this
}

# Update Lambda IAM Policy to allow SNS Publish
resource "aws_iam_role_policy" "lambda_sns_policy" {
  name = "${var.project_name}-lambda-sns-policy"
  role = aws_iam_role.lambda_backup_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sns:Publish"
      Resource = aws_sns_topic.backup_notifications.arn
    }]
  })
}




# Lambda function for S3 backup
resource "aws_lambda_function" "backup_function" {
  filename      = data.archive_file.lambda_backup_zip.output_path
  function_name = "${var.project_name}-backup-function-${local.bucket_suffix}"
  role          = aws_iam_role.lambda_backup_role.arn
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.9"
  timeout       = var.lambda_timeout
  memory_size   = var.lambda_memory_size
  
  source_code_hash = data.archive_file.lambda_backup_zip.output_base64sha256
  
  environment {
    variables = {
      SOURCE_BUCKET  = aws_s3_bucket.primary.id
      BACKUP_BUCKETS = "${aws_s3_bucket.backup.id},${aws_s3_bucket.secondary_backup.id}"
      SNS_TOPIC_ARN  = aws_sns_topic.backup_notifications.arn
    }
  }
  
  tags = local.common_tags
  
  depends_on = [
    aws_iam_role_policy.lambda_backup_policy,
    aws_cloudwatch_log_group.lambda_backup_logs
  ]
}

# CloudWatch log group for Lambda function
resource "aws_cloudwatch_log_group" "lambda_backup_logs" {
  name              = "/aws/lambda/${var.project_name}-backup-function-${local.bucket_suffix}"
  retention_in_days = 14
  tags              = local.common_tags
}

# =====================================================
# EVENTBRIDGE RULE FOR SCHEDULING
# =====================================================

# EventBridge rule for scheduled backup execution
resource "aws_cloudwatch_event_rule" "backup_schedule" {
  name                = "${var.project_name}-backup-schedule-${local.bucket_suffix}"
  description         = "Trigger S3 backup function on schedule"
  schedule_expression = var.backup_schedule
  tags                = local.common_tags
}

# EventBridge target for Lambda function
resource "aws_cloudwatch_event_target" "lambda_target" {
  rule      = aws_cloudwatch_event_rule.backup_schedule.name
  target_id = "LambdaTarget"
  arn       = aws_lambda_function.backup_function.arn
}

# Permission for EventBridge to invoke Lambda function
resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.backup_function.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.backup_schedule.arn
}

data "archive_file" "lambda_backup_zip" {
  type        = "zip"
  output_path = "${path.module}/lambda_function.zip"

  source {
    filename = "lambda_function.py"
    # This 'content' block replaces the need for templatefile()
    content  = <<-EOT
import boto3
import os
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

def lambda_handler(event, context):
    s3 = boto3.client('s3')
    sns = boto3.client('sns')
    
    source = os.environ.get('SOURCE_BUCKET')
    # Split the comma-separated list from Terraform
    destinations = os.environ.get('BACKUP_BUCKETS', '').split(',')
    sns_topic = os.environ.get('SNS_TOPIC_ARN')
    
    report = {"success": 0, "failures": 0, "details": []}

    try:
        paginator = s3.get_paginator('list_objects_v2')
        for page in paginator.paginate(Bucket=source):
            if 'Contents' not in page:
                continue
                
            for obj in page['Contents']:
                key = obj['Key']
                # Replicate to every destination bucket
                for dest in destinations:
                    try:
                        s3.copy_object(
                            CopySource={'Bucket': source, 'Key': key},
                            Bucket=dest.strip(),
                            Key=key
                        )
                        report["success"] += 1
                    except Exception as e:
                        report["failures"] += 1
                        report["details"].append(f"Failed {key} to {dest}: {str(e)}")

        status = "HEALTHY" if report["failures"] == 0 else "DEGRADED"
        msg = f"Geo-Redundant Backup {status}\nCopied: {report['success']}\nErrors: {len(report['details'])}"

    except Exception as e:
        status = "CRITICAL_FAILURE"
        msg = f"System Error: {str(e)}"

    if sns_topic:
        sns.publish(TopicArn=sns_topic, Subject=f"Backup Status: {status}", Message=msg)
    
    return {'statusCode': 200 if status != "CRITICAL_FAILURE" else 500, 'body': msg}

EOT
  }
}


