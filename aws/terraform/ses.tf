resource "aws_ses_email_identity" "sender" {
  email = local.dev_sender_email
}