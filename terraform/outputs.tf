# Everything you type into the Palo Alto, in one place.
# Show the keys with: terraform output -raw tunnel1_psk

output "tunnel1_aws_outside_ip" {
  description = "AWS_T1: the Palo Alto IKE gateway aws-t1 peer address."
  value       = aws_vpn_connection.hospital_a.tunnel1_address
}

output "tunnel2_aws_outside_ip" {
  description = "AWS_T2: the Palo Alto IKE gateway aws-t2 peer address."
  value       = aws_vpn_connection.hospital_a.tunnel2_address
}

output "tunnel1_inside" {
  description = "tunnel.1 on the Palo Alto, and its BGP peer on AWS."
  value = {
    palo_alto_tunnel_1 = "${aws_vpn_connection.hospital_a.tunnel1_cgw_inside_address}/30"
    aws_bgp_peer       = aws_vpn_connection.hospital_a.tunnel1_vgw_inside_address
  }
}

output "tunnel2_inside" {
  description = "tunnel.2 on the Palo Alto, and its BGP peer on AWS."
  value = {
    palo_alto_tunnel_2 = "${aws_vpn_connection.hospital_a.tunnel2_cgw_inside_address}/30"
    aws_bgp_peer       = aws_vpn_connection.hospital_a.tunnel2_vgw_inside_address
  }
}

output "tunnel1_psk" {
  description = "Pre-shared key for aws-t1."
  value       = aws_vpn_connection.hospital_a.tunnel1_preshared_key
  sensitive   = true
}

output "tunnel2_psk" {
  description = "Pre-shared key for aws-t2."
  value       = aws_vpn_connection.hospital_a.tunnel2_preshared_key
  sensitive   = true
}

output "palo_alto_local_identification" {
  description = "Set this as Local Identification (IP address) on both IKE gateways."
  value       = var.home_ip
}

output "vendor_app_instance_id" {
  description = "For: aws ec2-instance-connect ssh --instance-id <id> --connection-type eice"
  value       = aws_instance.vendor_app.id
}

output "test_from_linux_client" {
  description = "Run on the Linux client in EVE-NG once BGP is up."
  value       = "curl http://10.100.11.10:8080   (expect: sees you as 100.64.1.10)"
}

output "palo_alto_config" {
  description = "The complete hospital-a-fw configuration with this VPN's values filled in. Save it: terraform output -raw palo_alto_config > hospital-a-fw.set"
  sensitive   = true
  value = templatefile("${path.module}/templates/palo-alto-hospital-a.set.tftpl", {
    home_ip       = var.home_ip
    t1_outside    = aws_vpn_connection.hospital_a.tunnel1_address
    t2_outside    = aws_vpn_connection.hospital_a.tunnel2_address
    t1_psk        = aws_vpn_connection.hospital_a.tunnel1_preshared_key
    t2_psk        = aws_vpn_connection.hospital_a.tunnel2_preshared_key
    t1_cgw_inside = aws_vpn_connection.hospital_a.tunnel1_cgw_inside_address
    t2_cgw_inside = aws_vpn_connection.hospital_a.tunnel2_cgw_inside_address
    t1_aws_inside = aws_vpn_connection.hospital_a.tunnel1_vgw_inside_address
    t2_aws_inside = aws_vpn_connection.hospital_a.tunnel2_vgw_inside_address
  })
}

output "vpn_connection_id" {
  description = "For: aws ec2 describe-vpn-connections --vpn-connection-ids <id>"
  value       = aws_vpn_connection.hospital_a.id
}

output "rt_vendor_id" {
  description = "rt-downrange-cloud. Check it learned 100.64.1.0/24: aws ec2 search-transit-gateway-routes --transit-gateway-route-table-id <id> --filters Name=type,Values=propagated"
  value       = aws_ec2_transit_gateway_route_table.vendor.id
}

# ---- Where to look on the AWS side (monitoring.tf) ----

output "watch_dashboard" {
  description = "CloudWatch dashboard: tunnel state, traffic, latest flows and IKE log lines."
  value       = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards/dashboard/${aws_cloudwatch_dashboard.lab.dashboard_name}"
}

output "watch_network_manager" {
  description = "Network Manager: topology and events for the Transit Gateway (allow a few minutes after apply)."
  value       = "https://us-west-2.console.aws.amazon.com/networkmanager/home?region=us-west-2#/networks/${aws_networkmanager_global_network.lab.id}/topology"
}

output "watch_vpn_tunnels" {
  description = "Site-to-Site VPN console, Tunnel details tab."
  value       = "https://${var.region}.console.aws.amazon.com/vpcconsole/home?region=${var.region}#VpnConnectionDetails:VpnConnectionId=${aws_vpn_connection.hospital_a.id}"
}

output "watch_log_groups" {
  description = "CloudWatch log groups (Logs Insights works on all three)."
  value = {
    vpn_ike = aws_cloudwatch_log_group.vpn_hospital_a.name
    vpc     = aws_cloudwatch_log_group.vpc_flow.name
    tgw     = aws_cloudwatch_log_group.tgw_flow.name
  }
}
