# downrange-cloud-app at 10.100.11.10. A tiny Python web server on TCP 8080 answers
# every request with the source address it saw, so one curl from the Linux
# client proves the NAT: it should say 100.64.1.10, never 10.0.1.10.
# You reach the instance through an EC2 Instance Connect Endpoint (no public
# IP, no bastion, no SSH open to the internet).

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_security_group" "eice" {
  name        = "downrange-cloud-eice-sg"
  description = "EC2 Instance Connect Endpoint"
  vpc_id      = aws_vpc.vendor.id

  egress {
    description = "SSH to instances in the VPC"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.vendor_cidr]
  }
}

resource "aws_security_group" "vendor_app" {
  name        = "downrange-cloud-app-sg"
  description = "downrange-cloud-app: hospitals by NAT range only"
  vpc_id      = aws_vpc.vendor.id

  ingress {
    description = "Ping from hospital NAT ranges"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = ["100.64.0.0/16"]
  }

  ingress {
    description = "Web test from hospital NAT ranges"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["100.64.0.0/16"]
  }

  ingress {
    description = "HL7 (MLLP) from hospital NAT ranges"
    from_port   = 2575
    to_port     = 2575
    protocol    = "tcp"
    cidr_blocks = ["100.64.0.0/16"]
  }

  ingress {
    description     = "SSH only through the Instance Connect Endpoint"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.eice.id]
  }

  egress {
    description = "Replies and monitoring toward hospitals"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_ec2_instance_connect_endpoint" "vendor" {
  subnet_id          = aws_subnet.private_a.id
  security_group_ids = [aws_security_group.eice.id]

  # Off, so connections reach downrange-cloud-app from the endpoint's address and the
  # "SSH only from the endpoint" security group rule matches.
  preserve_client_ip = false
  tags               = { Name = "downrange-cloud-eice" }
}

resource "aws_instance" "vendor_app" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.private_a.id
  private_ip             = "10.100.11.10"
  vpc_security_group_ids = [aws_security_group.vendor_app.id]

  metadata_options {
    http_tokens = "required" # IMDSv2 only
  }

  user_data = <<-EOF
    #!/bin/bash
    cat > /usr/local/bin/whoami-server.py <<'PY'
    from http.server import BaseHTTPRequestHandler, HTTPServer
    class H(BaseHTTPRequestHandler):
        def do_GET(self):
            msg = f"downrange-cloud-app 10.100.11.10 sees you as {self.client_address[0]}\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(msg.encode())
    HTTPServer(("0.0.0.0", 8080), H).serve_forever()
    PY
    cat > /etc/systemd/system/whoami.service <<'UNIT'
    [Unit]
    Description=whoami test server on 8080
    After=network-online.target
    [Service]
    ExecStart=/usr/bin/python3 /usr/local/bin/whoami-server.py
    Restart=always
    [Install]
    WantedBy=multi-user.target
    UNIT
    systemctl daemon-reload
    systemctl enable --now whoami.service
  EOF

  tags = { Name = "downrange-cloud-app" }
}
