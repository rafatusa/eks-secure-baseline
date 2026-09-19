# AWS publishes the EstimatedCharges billing metric ONLY in us-east-1,
# regardless of where resources live. This aliased provider keeps the alarm
# correct even if aws_region changes later.
provider "aws" {
  alias  = "billing"
  region = "us-east-1"

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "udap"
      Component = "eks-secure-baseline"
    }
  }
}

locals {
  billing_alarm_enabled = var.billing_alarm_email != ""
}

resource "aws_sns_topic" "billing" {
  count    = local.billing_alarm_enabled ? 1 : 0
  provider = aws.billing

  name = "${var.project_name}-billing-alerts"

  tags = {
    Name = "${var.project_name}-billing-alerts"
  }
}

resource "aws_sns_topic_subscription" "billing_email" {
  count    = local.billing_alarm_enabled ? 1 : 0
  provider = aws.billing

  topic_arn = aws_sns_topic.billing[0].arn
  protocol  = "email"
  endpoint  = var.billing_alarm_email
}

# Cost guardrail. This account previously accumulated roughly $195/month of
# idle infrastructure (an unused ElastiCache cluster, orphaned load balancers
# and NAT gateways) that no alarm was watching.
resource "aws_cloudwatch_metric_alarm" "billing" {
  count    = local.billing_alarm_enabled ? 1 : 0
  provider = aws.billing

  alarm_name          = "${var.project_name}-estimated-charges"
  alarm_description   = "Estimated monthly AWS charges exceeded $${var.billing_alarm_threshold_usd}."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "EstimatedCharges"
  namespace           = "AWS/Billing"
  period              = 21600 # 6 hours — the publish interval for this metric
  statistic           = "Maximum"
  threshold           = var.billing_alarm_threshold_usd
  treat_missing_data  = "notBreaching"

  dimensions = {
    Currency = "USD"
  }

  alarm_actions = [aws_sns_topic.billing[0].arn]

  tags = {
    Name = "${var.project_name}-billing-alarm"
  }
}
