resource "aws_dynamodb_table" "sessions" {
  name         = "svod-sessions"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "tokenHash"

  attribute {
    name = "tokenHash"
    type = "S"
  }

  ttl {
    attribute_name = "expiresAt"
    enabled        = true
  }
}

resource "aws_dynamodb_table" "magic_links" {
    name        = "svod-magic-links"
    billing_mode = "PAY_PER_REQUEST"
    hash_key    = "tokenHash"

    attribute {
        name = "tokenHash"
        type = "S"
    }

    ttl {
        attribute_name = "expiresAt"
        enabled        = true
    }
   
}

resource "aws_dynamodb_table" "entitlements" {
    name        = "svod-entitlements"
    billing_mode = "PAY_PER_REQUEST"
    hash_key    = "userEmail"
    range_key   = "productId"

    attribute {
        name = "userEmail"
        type = "S"
    }

    attribute {
        name = "productId"
        type = "S"
    }
}

resource "aws_dynamodb_table" "devices" {
    name = "svod-devices"
    billing_mode = "PAY_PER_REQUEST"
    hash_key    = "userEmail"
    range_key   = "deviceHash"

    attribute {
        name = "userEmail"
        type = "S"
    }

    attribute {
        name = "deviceHash"
        type = "S"
    }
}

resource "aws_dynamodb_table" "play_events" {
  name         = "svod-play-events"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "userEmail"
  range_key    = "createdAt"

  attribute {
    name = "userEmail"
    type = "S"
  }

  attribute {
    name = "createdAt"
    type = "N"
  }

  ttl {
    attribute_name = "expiresAt"
    enabled        = true
  }
}

resource "aws_dynamodb_table" "users" {
  name         = "svod-users"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "email"

  attribute {
    name = "email"
    type = "S"
  }
}

resource "aws_dynamodb_table" "users" {
  name         = "svod-users"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "email"

  attribute {
    name = "email"
    type = "S"
  }
}

resource "aws_dynamodb_table" "orders" {
  name         = "svod-orders"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "orderId"

  attribute {
    name = "orderId"
    type = "S"
  }

  attribute {
    name = "claim"
    type = "S"
  }

  global_secondary_index {
    name            = "claim-index"
    hash_key        = "claim"
    projection_type = "ALL"
  }
}