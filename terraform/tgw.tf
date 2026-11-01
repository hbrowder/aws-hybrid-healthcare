# Transit Gateway with default association and propagation OFF, so nothing
# leaks between attachments unless a route table says so (Diagram 3).

resource "aws_ec2_transit_gateway" "vendor" {
  description                     = "downrange-cloud-tgw"
  amazon_side_asn                 = 64512
  default_route_table_association = "disable"
  default_route_table_propagation = "disable"
  vpn_ecmp_support                = "enable"
  dns_support                     = "enable"
  tags                            = { Name = "downrange-cloud-tgw" }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "vendor" {
  transit_gateway_id                              = aws_ec2_transit_gateway.vendor.id
  vpc_id                                          = aws_vpc.vendor.id
  subnet_ids                                      = [aws_subnet.private_a.id, aws_subnet.private_b.id]
  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false
  tags                                            = { Name = "downrange-cloud-attach" }
}

resource "aws_ec2_transit_gateway_route_table" "vendor" {
  transit_gateway_id = aws_ec2_transit_gateway.vendor.id
  tags               = { Name = "rt-downrange-cloud" }
}

resource "aws_ec2_transit_gateway_route_table" "hospital_a" {
  transit_gateway_id = aws_ec2_transit_gateway.vendor.id
  tags               = { Name = "rt-hospital-a" }
}

# Association: which table each attachment's traffic is looked up in.
resource "aws_ec2_transit_gateway_route_table_association" "vendor" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.vendor.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.vendor.id
}

resource "aws_ec2_transit_gateway_route_table_association" "hospital_a" {
  transit_gateway_attachment_id  = aws_vpn_connection.hospital_a.transit_gateway_attachment_id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.hospital_a.id
}

# Propagation: whose routes are copied into which table.
# Hospital A's table learns only the vendor (10.100.0.0/16) ...
resource "aws_ec2_transit_gateway_route_table_propagation" "vendor_into_hospital_a" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.vendor.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.hospital_a.id
}

# ... and the vendor's table learns 100.64.1.0/24 from Hospital A over BGP.
resource "aws_ec2_transit_gateway_route_table_propagation" "hospital_a_into_vendor" {
  transit_gateway_attachment_id  = aws_vpn_connection.hospital_a.transit_gateway_attachment_id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.vendor.id
}
