# The cloud-side view (M6): what the Palo Alto's Monitor tab shows you, but from AWS.
#
#   VPN tunnel logs   AWS's own IKE/IPsec log per tunnel        (the AWS side of ikemgr.log)
#   Flow logs         every flow through the vendor VPC and the Transit Gateway
#   Alarms + email    TunnelState per tunnel: email when a tunnel drops and when it recovers
#   Dashboard         tunnel state, tunnel traffic, latest flows and IKE lines on one page
#   Network Manager   drawn topology + event timeline for the Transit Gateway and its VPN
#
# Everything here is destroyed with the rest. Lab cost: cents per session.

# ---- Log groups (kept 1 day: this is a lab) --------------------------------

resource "aws_cloudwatch_log_group" "vpn_hospital_a" {
  name              = "/downrange-cloud/vpn-hospital-a"
  retention_in_days = 1
}

resource "aws_cloudwatch_log_group" "vpc_flow" {
  name              = "/downrange-cloud/vpc-flow"
  retention_in_days = 1
}

resource "aws_cloudwatch_log_group" "tgw_flow" {
  name              = "/downrange-cloud/tgw-flow"
  retention_in_days = 1
}

# ---- Flow logs ---------------------------------------------------------------

# Flow logs need permission to write into CloudWatch Logs.
resource "aws_iam_role" "flow_logs" {
  name = "downrange-cloud-flow-logs"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "flow_logs" {
  name = "write-flow-logs"
  role = aws_iam_role.flow_logs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams",
      ]
      Resource = [
        "${aws_cloudwatch_log_group.vpc_flow.arn}:*",
        "${aws_cloudwatch_log_group.tgw_flow.arn}:*",
      ]
    }]
  })
}

# Vendor VPC: every accepted and rejected flow, e.g. 100.64.1.10 -> 10.100.11.10:8080.
resource "aws_flow_log" "vpc" {
  vpc_id                   = aws_vpc.vendor.id
  traffic_type             = "ALL"
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.vpc_flow.arn
  iam_role_arn             = aws_iam_role.flow_logs.arn
  max_aggregation_interval = 60
  tags                     = { Name = "downrange-cloud-vpc-flow" }
}

# Transit Gateway: which attachment each flow came in on and went out of.
resource "aws_flow_log" "tgw" {
  transit_gateway_id       = aws_ec2_transit_gateway.vendor.id
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.tgw_flow.arn
  iam_role_arn             = aws_iam_role.flow_logs.arn
  max_aggregation_interval = 60 # the only value Transit Gateway flow logs accept
  tags                     = { Name = "downrange-cloud-tgw-flow" }
}

# ---- Alarms -> email ----------------------------------------------------------

resource "aws_sns_topic" "alerts" {
  name = "downrange-cloud-alerts"
}

# AWS emails a confirmation link first. Until you click it, no alarm mail arrives.
# Every rebuild creates a new subscription, so expect a new confirmation email each time.
resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

locals {
  tunnels = {
    "aws-t1" = aws_vpn_connection.hospital_a.tunnel1_address
    "aws-t2" = aws_vpn_connection.hospital_a.tunnel2_address
  }
}

# TunnelState is 1 when the tunnel is up, 0 when down. One alarm per tunnel.
# Expect an ALARM email right after apply (the firewall isn't loaded yet), then OK
# once the tunnels come up. That pair of emails is the first thing to look at.
resource "aws_cloudwatch_metric_alarm" "tunnel_down" {
  for_each = local.tunnels

  alarm_name          = "hospital-a-${each.key}-down"
  alarm_description   = "Hospital A tunnel ${each.key} (${each.value}) is down."
  namespace           = "AWS/VPN"
  metric_name         = "TunnelState"
  dimensions          = { TunnelIpAddress = each.value }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

# ---- Dashboard -------------------------------------------------------------------

resource "aws_cloudwatch_dashboard" "lab" {
  dashboard_name = "downrange-cloud-hospital-a"
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title  = "Tunnel state (1 = up)"
          region = var.region
          stat   = "Maximum"
          period = 60
          view   = "timeSeries"
          yAxis  = { left = { min = 0, max = 1 } }
          metrics = [
            for name, ip in local.tunnels : ["AWS/VPN", "TunnelState", "TunnelIpAddress", ip, { label = name }]
          ]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title  = "Tunnel traffic (bytes per minute)"
          region = var.region
          stat   = "Sum"
          period = 60
          view   = "timeSeries"
          metrics = concat(
            [for name, ip in local.tunnels : ["AWS/VPN", "TunnelDataIn", "TunnelIpAddress", ip, { label = "${name} in" }]],
            [for name, ip in local.tunnels : ["AWS/VPN", "TunnelDataOut", "TunnelIpAddress", ip, { label = "${name} out" }]],
          )
        }
      },
      {
        type = "log", x = 0, y = 6, width = 24, height = 6
        properties = {
          title  = "Vendor VPC flows, real traffic only (latest 25)"
          region = var.region
          view   = "table"
          query  = "SOURCE '${aws_cloudwatch_log_group.vpc_flow.name}' | filter @message like /ACCEPT|REJECT/ | fields @timestamp, interfaceId, srcAddr, dstAddr, dstPort, action | sort @timestamp desc | limit 25"
        }
      },
      {
        type = "log", x = 0, y = 12, width = 24, height = 6
        properties = {
          title  = "AWS-side IKE/IPsec log, Hospital A (latest 25)"
          region = var.region
          view   = "table"
          query  = "SOURCE '${aws_cloudwatch_log_group.vpn_hospital_a.name}' | fields @timestamp, @message | sort @timestamp desc | limit 25"
        }
      },
    ]
  })
}

# ---- Network Manager ---------------------------------------------------------------
# A global service whose API lives in us-west-2, so it gets its own provider alias.
# Nothing is deployed in Oregon: it only draws and watches the us-east-1 Transit Gateway.

provider "aws" {
  alias  = "netmgr"
  region = "us-west-2"

  default_tags {
    tags = {
      Project = "aws-hybrid-healthcare"
      Company = "Downrange Cloud"
      Owner   = "harold"
    }
  }
}

resource "aws_networkmanager_global_network" "lab" {
  provider    = aws.netmgr
  description = "downrange-cloud"
  tags        = { Name = "downrange-cloud-global-network" }
}

resource "aws_networkmanager_transit_gateway_registration" "vendor" {
  provider            = aws.netmgr
  global_network_id   = aws_networkmanager_global_network.lab.id
  transit_gateway_arn = aws_ec2_transit_gateway.vendor.arn
}
