# downrange-cloud-app-ha: the same "who sees you" app, made highly available (SAA-C03 resilience).
#
#   Hospital client --VPN/TGW--> internal ALB (2 AZs, port 8080)
#                                   |-> instance in us-east-1a  (Auto Scaling group)
#                                   '-> instance in us-east-1b
#
# Each reply names the instance and AZ that answered, the client it saw (X-Forwarded-For,
# so still 100.64.1.x after the hospital NAT) and the load balancer address it came through.
# Kill one instance: the ALB keeps answering from the other AZ and Auto Scaling replaces it.
#
# Port 8080 on purpose: the Palo Alto already allows tcp-8080 to 10.100.0.0/16, so no
# firewall change. The original fixed instance at 10.100.11.10 stays for checks 8-10.

# ---- Security groups ------------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "downrange-cloud-alb-sg"
  description = "Internal ALB: hospitals by NAT range only"
  vpc_id      = aws_vpc.vendor.id

  ingress {
    description = "App from hospital NAT ranges"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["100.64.0.0/16"]
  }

  egress {
    description = "To the app instances"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [var.vendor_cidr]
  }
}

resource "aws_security_group" "app_ha" {
  name        = "downrange-cloud-app-ha-sg"
  description = "downrange-cloud-app-ha: only the ALB, plus SSH via Instance Connect"
  vpc_id      = aws_vpc.vendor.id

  ingress {
    description     = "App traffic only from the ALB"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    description     = "SSH only through the Instance Connect Endpoint"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.eice.id]
  }

  egress {
    description = "Replies"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ---- Load balancer ----------------------------------------------------------------

resource "aws_lb" "app" {
  name               = "downrange-cloud-alb"
  internal           = true # private IPs only; reached over the VPN like everything else
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.private_a.id, aws_subnet.private_b.id]
}

resource "aws_lb_target_group" "app" {
  name                 = "downrange-cloud-app-tg"
  port                 = 8080
  protocol             = "HTTP"
  vpc_id               = aws_vpc.vendor.id
  deregistration_delay = 30 # lab: drain fast so failover is quick to watch

  health_check {
    path                = "/"
    port                = "8080"
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200"
  }
}

resource "aws_lb_listener" "app" {
  load_balancer_arn = aws_lb.app.arn
  port              = 8080
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# ---- Instances: launch template + Auto Scaling across two AZs -------------------------

resource "aws_launch_template" "app" {
  name_prefix            = "downrange-cloud-app-ha-"
  image_id               = data.aws_ssm_parameter.al2023.value
  instance_type          = "t3.micro"
  vpc_security_group_ids = [aws_security_group.app_ha.id]

  metadata_options {
    http_tokens = "required" # IMDSv2 only
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    cat > /usr/local/bin/whoami-ha.py <<'PY'
    import urllib.request
    from http.server import BaseHTTPRequestHandler, HTTPServer

    def imds(path):
        tok = urllib.request.urlopen(urllib.request.Request(
            "http://169.254.169.254/latest/api/token", method="PUT",
            headers={"X-aws-ec2-metadata-token-ttl-seconds": "300"})).read().decode()
        return urllib.request.urlopen(urllib.request.Request(
            "http://169.254.169.254/latest/meta-data/" + path,
            headers={"X-aws-ec2-metadata-token": tok})).read().decode()

    ME, AZ = imds("instance-id"), imds("placement/availability-zone")

    class H(BaseHTTPRequestHandler):
        def do_GET(self):
            client = self.headers.get("X-Forwarded-For", self.client_address[0]).split(",")[0].strip()
            msg = f"downrange-cloud-app-ha {ME} in {AZ} sees you as {client} (via ALB {self.client_address[0]})\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(msg.encode())
        def log_message(self, *args):
            pass  # health checks every 10 s would fill the journal

    HTTPServer(("0.0.0.0", 8080), H).serve_forever()
    PY
    cat > /etc/systemd/system/whoami-ha.service <<'UNIT'
    [Unit]
    Description=whoami HA test server on 8080
    After=network-online.target
    [Service]
    ExecStart=/usr/bin/python3 /usr/local/bin/whoami-ha.py
    Restart=always
    [Install]
    WantedBy=multi-user.target
    UNIT
    systemctl daemon-reload
    systemctl enable --now whoami-ha.service
  EOF
  )
}

resource "aws_autoscaling_group" "app" {
  name                      = "downrange-cloud-app-ha"
  min_size                  = 2
  desired_capacity          = 2
  max_size                  = 4
  vpc_zone_identifier       = [aws_subnet.private_a.id, aws_subnet.private_b.id]
  target_group_arns         = [aws_lb_target_group.app.arn]
  health_check_type         = "ELB" # replace instances the ALB marks unhealthy, not just stopped ones
  health_check_grace_period = 120

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  # Provider default_tags don't reach instances an Auto Scaling group launches.
  dynamic "tag" {
    for_each = merge(local.common_tags, { Name = "downrange-cloud-app-ha" })
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }
}

# ---- Watch it -------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "app_unhealthy" {
  alarm_name          = "downrange-cloud-app-ha-unhealthy"
  alarm_description   = "An instance behind the ALB is failing health checks."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  dimensions          = { LoadBalancer = aws_lb.app.arn_suffix, TargetGroup = aws_lb_target_group.app.arn_suffix }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

output "ha_app_url" {
  description = "Check 11 from a hospital client: repeat it and watch the instance and AZ change."
  value       = "curl http://${aws_lb.app.dns_name}:8080   (expect: sees you as 100.64.1.x, alternating AZs)"
}
