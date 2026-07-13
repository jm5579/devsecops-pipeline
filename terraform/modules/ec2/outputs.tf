# terraform/modules/ec2/outputs.tf

output "instance_id" {
  value = aws_instance.app.id
}

output "security_group_id" {
  value = aws_security_group.app.id
}

output "private_ip" {
  value = aws_instance.app.private_ip
}
