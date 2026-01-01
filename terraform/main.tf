provider "aws" {
  region = "ap-southeast-2"
}

# S3
resource "aws_s3_bucket" "sentiment_bucket" {
  bucket = "snowflake-platform-sentiment"
}

resource "aws_s3_bucket_lifecycle_configuration" "sentiment" {
  bucket = aws_s3_bucket.sentiment_bucket.id

  rule {
    id     = "raw-sentiment-data-lifecycle"
    status = "Enabled"

  filter {
      prefix = ""
    }

    transition {
      days          = 30
      storage_class = "INTELLIGENT_TIERING"
    }

    expiration {
      days = 365
    }
  }
}

resource "aws_s3_bucket" "sentiment_notifications_bucket" {
  bucket = "snowflake-platform-sentiment-notifications"
}

# Lambda
data "archive_file" "python_layer" {
  type        = "zip"
  source_dir  = "${path.module}/lambda_layer"
  output_path = "${path.module}/lambda_layer/python.zip"
}

resource "aws_lambda_layer_version" "python_layer" {
  filename            = data.archive_file.python_layer.output_path
  layer_name          = "python_layer"
  compatible_runtimes = ["python3.10"]
  description         = "Python libraries for Lambda"

  source_code_hash = data.archive_file.python_layer.output_base64sha256
}

data "aws_iam_policy_document" "assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

# Lambda 1: sentiment Data
data "aws_iam_policy_document" "sns_publish" {
  statement {
    effect = "Allow"

    actions = [
      "sns:Publish"
    ]

    resources = [
      aws_sns_topic.sentiment_notifications.arn
    ]
  }
}

resource "aws_iam_role" "sentiment_lambda_role" {
  name               = "snowflake-platform-sentiment-role"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

resource "aws_iam_role_policy_attachment" "sentiment_basic_execution" {
  role       = aws_iam_role.sentiment_lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_sns_publish" {
  role = aws_iam_role.sentiment_lambda_role.name    
  policy = data.aws_iam_policy_document.sns_publish.json
}

resource "aws_iam_role_policy" "lambda_sentiment_s3_put" {
  role = aws_iam_role.sentiment_lambda_role.name    
  policy = data.aws_iam_policy_document.s3_put.json
}

data "archive_file" "sentiment" {
  type        = "zip"
  source_dir = "${path.module}/lambdas/sentiment"
  output_path = "${path.module}/lambdas/sentiment/sentiment.zip"
}

resource "aws_lambda_function" "sentiment" {
  filename         = data.archive_file.sentiment.output_path
  function_name    = "sentiment"
  role             = aws_iam_role.sentiment_lambda_role.arn
  handler          = "sentiment.handler"
  source_code_hash = data.archive_file.sentiment.output_base64sha256
  runtime = "python3.10"

  layers = [aws_lambda_layer_version.python_layer.arn]

  environment {
    variables = {
      ALPHA_VANTAGE_API_KEY = var.alpha_vantage_api_key
      SNS_TOPIC_ARN         = aws_sns_topic.sentiment_notifications.arn
      S3_BUCKET_NAME        = aws_s3_bucket.sentiment_bucket.bucket
    }
  }
}

resource "aws_cloudwatch_event_rule" "every_day" {
    name = "every-1-day"
    description = "Fires every day"
    schedule_expression = "rate(1 day)"
    state = var.is_project_live ? "ENABLED" : "DISABLED"
}

resource "aws_cloudwatch_event_target" "sentiment" {
    rule = aws_cloudwatch_event_rule.every_day.name
    target_id = "sentiment-target"
    arn = aws_lambda_function.sentiment.arn
}

resource "aws_lambda_permission" "eventbridge_invoke_sentiment" {
    statement_id = "AllowExecutionFromEventbridge"
    action = "lambda:InvokeFunction"
    function_name = aws_lambda_function.sentiment.function_name
    principal = "events.amazonaws.com"
    source_arn = aws_cloudwatch_event_rule.every_day.arn
}

# Lambda 2: sentiment Data Notifications into S3
data "aws_iam_policy_document" "sqs_handle_messages_s3" {
  statement {
    effect = "Allow"

    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes"
    ]

    resources = [
      aws_sqs_queue.sentiment_notifications_s3.arn
    ]
  }
}

data "aws_iam_policy_document" "s3_put" {
  statement {
    effect = "Allow"

    actions = [
      "s3:PutObject"
    ]

    resources = [
      "${aws_s3_bucket.sentiment_bucket.arn}/*",
      "${aws_s3_bucket.sentiment_notifications_bucket.arn}/*"
    ]
  }
}

resource "aws_iam_role" "sentiment_notifications_s3_lambda_role" {
  name               = "snowflake-platform-sentiment-notifications-s3-role"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

resource "aws_iam_role_policy_attachment" "sentiment_notifications_s3_basic_execution" {
  role       = aws_iam_role.sentiment_notifications_s3_lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_sqs_handle_messages_s3" {
  role = aws_iam_role.sentiment_notifications_s3_lambda_role.name 
  policy = data.aws_iam_policy_document.sqs_handle_messages_s3.json
}

resource "aws_iam_role_policy" "lambda_sentiment_notifications_s3_put" {
  role = aws_iam_role.sentiment_notifications_s3_lambda_role.name 
  policy = data.aws_iam_policy_document.s3_put.json
}

data "archive_file" "sentiment_notifications_s3" {
  type        = "zip"
  source_dir = "${path.module}/lambdas/sentiment_notifications_s3"
  output_path = "${path.module}/lambdas/sentiment_notifications_s3/sentiment_notifications_s3.zip"
}

resource "aws_lambda_function" "sentiment_notifications_s3" {
  filename         = data.archive_file.sentiment_notifications_s3.output_path
  function_name    = "sentiment-notifications-s3"
  role             = aws_iam_role.sentiment_notifications_s3_lambda_role.arn
  handler          = "sentiment_notifications_s3.handler"
  source_code_hash = data.archive_file.sentiment_notifications_s3.output_base64sha256
  runtime = "python3.10"

    environment {
        variables = {
        QUEUE_NAME = aws_sqs_queue.sentiment_notifications_s3.name
        BUCKET_NAME = aws_s3_bucket.sentiment_notifications_bucket.bucket
        }
    }
}

resource "aws_lambda_event_source_mapping" "sentiment_notifications_sqs_s3" {
  event_source_arn = aws_sqs_queue.sentiment_notifications_s3.arn
  function_name    = aws_lambda_function.sentiment_notifications_s3.arn
  batch_size       = 10          # Number of messages per invocation
  enabled          = true
}

# Lambda 3: sentiment Data Notifications into Slack
data "aws_iam_policy_document" "sqs_handle_messages_slack" {
  statement {
    effect = "Allow"

    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes"
    ]

    resources = [
      aws_sqs_queue.sentiment_notifications_slack.arn
    ]
  }
}

resource "aws_iam_role" "sentiment_notifications_slack_lambda_role" {
  name               = "snowflake-platform-sentiment-notifications-slack-role"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

resource "aws_iam_role_policy_attachment" "sentiment_notifications_lambda_basic_execution" {
  role       = aws_iam_role.sentiment_notifications_slack_lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_sqs_handle_messages_slack" {
  role = aws_iam_role.sentiment_notifications_slack_lambda_role.name 
  policy = data.aws_iam_policy_document.sqs_handle_messages_slack.json
}

data "archive_file" "sentiment_notifications_slack" {
  type        = "zip"
  source_dir = "${path.module}/lambdas/sentiment_notifications_slack"
  output_path = "${path.module}/lambdas/sentiment_notifications_slack/sentiment_notifications_slack.zip"
}

resource "aws_lambda_function" "sentiment_notifications_slack" {
  filename         = data.archive_file.sentiment_notifications_slack.output_path
  function_name    = "sentiment-notifications-slack"
  role             = aws_iam_role.sentiment_notifications_slack_lambda_role.arn
  handler          = "sentiment_notifications_slack.handler"
  source_code_hash = data.archive_file.sentiment_notifications_slack.output_base64sha256
  runtime = "python3.10"

  layers = [aws_lambda_layer_version.python_layer.arn]

    environment {
        variables = {
        SLACK_WEBHOOK_URL = var.slack_webhook_url
        }
    }
}

resource "aws_lambda_event_source_mapping" "sentiment_notifications_sqs_slack" {
  event_source_arn = aws_sqs_queue.sentiment_notifications_slack.arn
  function_name    = aws_lambda_function.sentiment_notifications_slack.arn
  batch_size       = 10          # Number of messages per invocation
  enabled          = true
}

# SNS
resource "aws_sns_topic" "sentiment_notifications" {
  name = "sentiment-notifications-topic"
}

# SQS
data "aws_iam_policy_document" "sns_send_message_to_sqs" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
    }

    actions = [
      "sqs:SendMessage"
    ]

    resources = [
      aws_sqs_queue.sentiment_notifications_s3.arn,
      aws_sqs_queue.sentiment_notifications_slack.arn
    ]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_sns_topic.sentiment_notifications.arn]
    }
  }
}

# Queue 1: notifications into S3
resource "aws_sqs_queue" "sentiment_notifications_s3" {
  name = "sentiment-notifications-s3-queue"
}

resource "aws_sqs_queue_policy" "sns_send_message_to_sqs_s3" {
  queue_url = aws_sqs_queue.sentiment_notifications_s3.id
  policy    = data.aws_iam_policy_document.sns_send_message_to_sqs.json
}

resource "aws_sns_topic_subscription" "sentiment_notifications_s3" {
  topic_arn = aws_sns_topic.sentiment_notifications.arn
  endpoint  = aws_sqs_queue.sentiment_notifications_s3.arn
  protocol  = "sqs"
}

# Queue 2: notifications into Slack
resource "aws_sqs_queue" "sentiment_notifications_slack" {
  name = "sentiment-notifications-slack-queue"
}

resource "aws_sqs_queue_policy" "sns_send_message_to_sqs_slack" {
  queue_url = aws_sqs_queue.sentiment_notifications_slack.id
  policy    = data.aws_iam_policy_document.sns_send_message_to_sqs.json
}

resource "aws_sns_topic_subscription" "sentiment_notifications_slack" {
  topic_arn = aws_sns_topic.sentiment_notifications.arn
  endpoint  = aws_sqs_queue.sentiment_notifications_slack.arn
  protocol  = "sqs"
}

# ECR
resource "aws_ecr_repository" "repository" {
  name                 = "snowflake-platform"
  image_tag_mutability = "MUTABLE"
  force_delete = true
}