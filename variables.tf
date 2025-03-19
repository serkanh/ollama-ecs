variable "aws_region" {
  description = "The AWS region to deploy resources"
  type        = string
  default     = "us-east-1"
}

variable "vpc_id" {
  description = "The ID of the VPC to deploy resources"
  type        = string
}

variable "webui_secret_key" {
  description = "Secret key for WebUI"
  type        = string
  sensitive   = true
}
# To get the latest AMI ID, run the following command:
# aws ec2 describe-images --owners amazon --filters "Name=name,Values=*amazon-ecs-optimized-ami-*" --query 'Images[*].[ImageId,CreationDate]' --output table
variable "ami_id" {
  description = "AMI ID for the GPU instance"
  type        = string
  default     = "ami-06180605a8fe2c296"
}

variable "ssh_key_name" {
  description = "The name of the SSH key pair to use for EC2 instances"
  type        = string
  default     = null  # Default to no SSH key
}
