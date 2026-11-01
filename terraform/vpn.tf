# Hospital A: customer gateway (your AT&T public IP) and the Site-to-Site VPN
# to downrange-cloud-tgw. Two tunnels, IKEv2, BGP, crypto pinned to match the Palo Alto
# profiles in the M2b lab (AES-256, SHA-256, DH group 14).

resource "aws_customer_gateway" "hospital_a" {
  bgp_asn    = var.hospital_asn
  ip_address = var.home_ip
  type       = "ipsec.1"
  tags       = { Name = "hospital-a-cgw" }
}

resource "aws_vpn_connection" "hospital_a" {
  customer_gateway_id = aws_customer_gateway.hospital_a.id
  transit_gateway_id  = aws_ec2_transit_gateway.vendor.id
  type                = "ipsec.1"
  static_routes_only  = false # BGP

  tunnel1_inside_cidr = "169.254.11.0/30"
  tunnel2_inside_cidr = "169.254.12.0/30"

  # AWS starts the IKE negotiation itself (through the AT&T port forwards), and
  # restarts a tunnel whose peer stops answering, so the lab comes up on its own.
  tunnel1_startup_action     = "start"
  tunnel2_startup_action     = "start"
  tunnel1_dpd_timeout_action = "restart"
  tunnel2_dpd_timeout_action = "restart"

  tunnel1_ike_versions                 = ["ikev2"]
  tunnel1_phase1_encryption_algorithms = ["AES256"]
  tunnel1_phase1_integrity_algorithms  = ["SHA2-256"]
  tunnel1_phase1_dh_group_numbers      = [14]
  tunnel1_phase2_encryption_algorithms = ["AES256"]
  tunnel1_phase2_integrity_algorithms  = ["SHA2-256"]
  tunnel1_phase2_dh_group_numbers      = [14]

  tunnel2_ike_versions                 = ["ikev2"]
  tunnel2_phase1_encryption_algorithms = ["AES256"]
  tunnel2_phase1_integrity_algorithms  = ["SHA2-256"]
  tunnel2_phase1_dh_group_numbers      = [14]
  tunnel2_phase2_encryption_algorithms = ["AES256"]
  tunnel2_phase2_integrity_algorithms  = ["SHA2-256"]
  tunnel2_phase2_dh_group_numbers      = [14]

  # AWS's own IKE/IPsec log for each tunnel, in CloudWatch (see monitoring.tf).
  tunnel1_log_options {
    cloudwatch_log_options {
      log_enabled       = true
      log_group_arn     = aws_cloudwatch_log_group.vpn_hospital_a.arn
      log_output_format = "text"
    }
  }
  tunnel2_log_options {
    cloudwatch_log_options {
      log_enabled       = true
      log_group_arn     = aws_cloudwatch_log_group.vpn_hospital_a.arn
      log_output_format = "text"
    }
  }

  # Pre-shared keys are left to AWS to generate. They come out as sensitive
  # outputs and are stored in plain text in terraform.tfstate: never commit it.

  tags = { Name = "hospital-a-vpn" }
}
