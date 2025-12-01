variable "is_project_live" {
  description = "Flag to indicate if the project is live"
  type        = bool
  default     = false
}

variable "slack_webhook_url" {
  description = "The Slack webhook URL for sending notifications"
  type        = string
  sensitive   = true
}

variable "alpha_vantage_api_key" {
  description = "API key for Alpha Vantage"
  type        = string
  sensitive   = true
}