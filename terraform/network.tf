# Vendor VPC: two private subnets in two Availability Zones (Diagram 1, bottom box).
# No internet gateway and no NAT gateway: nothing here needs the internet.

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "vendor" {
  cidr_block           = var.vendor_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "downrange-cloud-vpc" }
}

resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.vendor.id
  cidr_block        = "10.100.11.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]
  tags              = { Name = "downrange-cloud-private-a" }
}

resource "aws_subnet" "private_b" {
  vpc_id            = aws_vpc.vendor.id
  cidr_block        = "10.100.12.0/24"
  availability_zone = data.aws_availability_zones.available.names[1]
  tags              = { Name = "downrange-cloud-private-b" }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.vendor.id
  tags   = { Name = "downrange-cloud-private-rt" }
}

# The return path: every hospital NAT range goes to the Transit Gateway.
resource "aws_route" "hospitals_via_tgw" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "100.64.0.0/16"
  transit_gateway_id     = aws_ec2_transit_gateway.vendor.id

  # The route can't be created until the VPC attachment exists.
  depends_on = [aws_ec2_transit_gateway_vpc_attachment.vendor]
}

resource "aws_route_table_association" "private_a" {
  subnet_id      = aws_subnet.private_a.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_b" {
  subnet_id      = aws_subnet.private_b.id
  route_table_id = aws_route_table.private.id
}
