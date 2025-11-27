provider "aws" {
  region = "ap-southeast-2"
}

# S3
resource "aws_s3_bucket" "stock_data_bucket" {
  bucket = "snowflake-platform-stock-data"
}

resource "aws_s3_bucket" "stock_data_notifications_bucket" {
  bucket = "snowflake-platform-stock-data-notifications"
}

# Lambda
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

# Lambda 1: Stock Data
data "aws_iam_policy_document" "sns_publish" {
  statement {
    effect = "Allow"

    actions = [
      "sns:Publish"
    ]

    resources = [
      aws_sns_topic.stock_data_notifications.arn
    ]
  }
}

resource "aws_iam_role" "stock_data_lambda_role" {
  name               = "snowflake-platform-stock-data-role"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

resource "aws_iam_role_policy_attachment" "stock_data_basic_execution" {
  role       = aws_iam_role.stock_data_lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_sns_publish" {
  role = aws_iam_role.stock_data_lambda_role.name    
  policy = data.aws_iam_policy_document.sns_publish.json
}

data "archive_file" "stock_data" {
  type        = "zip"
  source_dir = "${path.module}/lambdas/stock_data"
  output_path = "${path.module}/lambdas/stock_data/stock_data.zip"
}

resource "aws_lambda_function" "stock_data" {
  filename         = data.archive_file.stock_data.output_path
  function_name    = "stock-data"
  role             = aws_iam_role.stock_data_lambda_role.arn
  handler          = "stock_data.handler"
  source_code_hash = data.archive_file.stock_data.output_base64sha256
  runtime = "python3.10"

    environment {
        variables = {
        SNS_TOPIC_ARN = aws_sns_topic.stock_data_notifications.arn
        }
    }
}

resource "aws_cloudwatch_event_rule" "every_minute" {
    name = "every-minute"
    description = "Fires every minute"
    schedule_expression = "rate(1 minute)"
    state = "DISABLED"
}

resource "aws_cloudwatch_event_target" "stock_data" {
    rule = aws_cloudwatch_event_rule.every_minute.name
    target_id = "stock-data-target"
    arn = aws_lambda_function.stock_data.arn
}

resource "aws_lambda_permission" "eventbridge_invoke_stock_data" {
    statement_id = "AllowExecutionFromEventbridge"
    action = "lambda:InvokeFunction"
    function_name = aws_lambda_function.stock_data.function_name
    principal = "events.amazonaws.com"
    source_arn = aws_cloudwatch_event_rule.every_minute.arn
}

# Lambda 2: Stock Data Notifications into S3
data "aws_iam_policy_document" "sqs_handle_messages_s3" {
  statement {
    effect = "Allow"

    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes"
    ]

    resources = [
      aws_sqs_queue.stock_data_notifications_s3.arn
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
      "${aws_s3_bucket.stock_data_notifications_bucket.arn}/*"
    ]
  }
}

resource "aws_iam_role" "stock_data_notifications_s3_lambda_role" {
  name               = "snowflake-platform-stock-data-notifications-s3-role"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

resource "aws_iam_role_policy_attachment" "stock_data_notifications_s3_basic_execution" {
  role       = aws_iam_role.stock_data_notifications_s3_lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_sqs_handle_messages_s3" {
  role = aws_iam_role.stock_data_notifications_s3_lambda_role.name 
  policy = data.aws_iam_policy_document.sqs_handle_messages_s3.json
}

resource "aws_iam_role_policy" "lambda_s3_put" {
  role = aws_iam_role.stock_data_notifications_s3_lambda_role.name 
  policy = data.aws_iam_policy_document.s3_put.json
}

data "archive_file" "stock_data_notifications_s3" {
  type        = "zip"
  source_dir = "${path.module}/lambdas/stock_data_notifications_s3"
  output_path = "${path.module}/lambdas/stock_data_notifications_s3/stock_data_notifications_s3.zip"
}

resource "aws_lambda_function" "stock_data_notifications_s3" {
  filename         = data.archive_file.stock_data_notifications_s3.output_path
  function_name    = "stock-data-notifications-s3"
  role             = aws_iam_role.stock_data_notifications_s3_lambda_role.arn
  handler          = "stock_data_notifications_s3.handler"
  source_code_hash = data.archive_file.stock_data_notifications_s3.output_base64sha256
  runtime = "python3.10"

    environment {
        variables = {
        QUEUE_NAME = aws_sqs_queue.stock_data_notifications_s3.name
        BUCKET_NAME = aws_s3_bucket.stock_data_notifications_bucket.bucket
        }
    }
}

resource "aws_lambda_event_source_mapping" "stock_data_notifications_sqs_s3" {
  event_source_arn = aws_sqs_queue.stock_data_notifications_s3.arn
  function_name    = aws_lambda_function.stock_data_notifications_s3.arn
  batch_size       = 10          # Number of messages per invocation
  enabled          = true
}

# Lambda 3: Stock Data Notifications into Slack
data "aws_iam_policy_document" "sqs_handle_messages_slack" {
  statement {
    effect = "Allow"

    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes"
    ]

    resources = [
      aws_sqs_queue.stock_data_notifications_slack.arn
    ]
  }
}

resource "aws_iam_role" "stock_data_notifications_slack_lambda_role" {
  name               = "snowflake-platform-stock-data-notifications-slack-role"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

resource "aws_iam_role_policy_attachment" "stock_data_notifications_lambda_basic_execution" {
  role       = aws_iam_role.stock_data_notifications_slack_lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_sqs_handle_messages_slack" {
  role = aws_iam_role.stock_data_notifications_slack_lambda_role.name 
  policy = data.aws_iam_policy_document.sqs_handle_messages_slack.json
}

data "archive_file" "stock_data_notifications_slack" {
  type        = "zip"
  source_dir = "${path.module}/lambdas/stock_data_notifications_slack"
  output_path = "${path.module}/lambdas/stock_data_notifications_slack/stock_data_notifications_slack.zip"
}

resource "aws_lambda_function" "stock_data_notifications_slack" {
  filename         = data.archive_file.stock_data_notifications_slack.output_path
  function_name    = "stock-data-notifications-slack"
  role             = aws_iam_role.stock_data_notifications_slack_lambda_role.arn
  handler          = "stock_data_notifications_slack.handler"
  source_code_hash = data.archive_file.stock_data_notifications_slack.output_base64sha256
  runtime = "python3.10"

    environment {
        variables = {
        SLACK_WEBHOOK_URL = "https://hooks.slack.com/services/dummy/webhook/url"
        }
    }
}

resource "aws_lambda_event_source_mapping" "stock_data_notifications_sqs_slack" {
  event_source_arn = aws_sqs_queue.stock_data_notifications_slack.arn
  function_name    = aws_lambda_function.stock_data_notifications_slack.arn
  batch_size       = 10          # Number of messages per invocation
  enabled          = true
}

# SNS
resource "aws_sns_topic" "stock_data_notifications" {
  name = "stock-data-notifications-topic"
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
      aws_sqs_queue.stock_data_notifications_s3.arn,
      aws_sqs_queue.stock_data_notifications_slack.arn
    ]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_sns_topic.stock_data_notifications.arn]
    }
  }
}

# Queue 1: notifications into S3
resource "aws_sqs_queue" "stock_data_notifications_s3" {
  name = "stock-data-notifications-s3-queue"
}

resource "aws_sqs_queue_policy" "sns_send_message_to_sqs_s3" {
  queue_url = aws_sqs_queue.stock_data_notifications_s3.id
  policy    = data.aws_iam_policy_document.sns_send_message_to_sqs.json
}

resource "aws_sns_topic_subscription" "stock_data_notifications_s3" {
  topic_arn = aws_sns_topic.stock_data_notifications.arn
  endpoint  = aws_sqs_queue.stock_data_notifications_s3.arn
  protocol  = "sqs"
}

# Queue 2: notifications into Slack
resource "aws_sqs_queue" "stock_data_notifications_slack" {
  name = "stock-data-notifications-slack-queue"
}

resource "aws_sqs_queue_policy" "sns_send_message_to_sqs_slack" {
  queue_url = aws_sqs_queue.stock_data_notifications_slack.id
  policy    = data.aws_iam_policy_document.sns_send_message_to_sqs.json
}

resource "aws_sns_topic_subscription" "stock_data_notifications_slack" {
  topic_arn = aws_sns_topic.stock_data_notifications.arn
  endpoint  = aws_sqs_queue.stock_data_notifications_slack.arn
  protocol  = "sqs"
}