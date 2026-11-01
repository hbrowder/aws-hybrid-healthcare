variable "region" {
  description = "AWS Region for the vendor side."
  type        = string
  default     = "us-east-1"
}

variable "home_ip" {
  description = "Your AT&T public IP (HOME_IP). Becomes the customer gateway address."
  type        = string

  validation {
    condition     = can(regex("^\\d{1,3}(\\.\\d{1,3}){3}$", var.home_ip))
    error_message = "home_ip must be a plain IPv4 address, like 203.0.113.10."
  }
}

variable "hospital_asn" {
  description = "Hospital A's BGP ASN (the Palo Alto)."
  type        = number
  default     = 65010
}

variable "hospital_nat_range" {
  description = "The range Hospital A NATs into. downrange-cloud-app sees this, never 10.0.1.0/24."
  type        = string
  default     = "100.64.1.0/24"
}

variable "alert_email" {
  description = "Where tunnel up/down alarms are emailed. AWS sends a confirmation link first."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email))
    error_message = "alert_email must be an email address. Set it in terraform.tfvars."
  }
}

variable "vendor_cidr" {
  description = "Vendor VPC range."
  type        = string
  default     = "10.100.0.0/16"
}
