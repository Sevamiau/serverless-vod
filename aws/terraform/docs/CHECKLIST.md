# Post-apply checklist

Every `terraform apply` creates a **new** random bucket suffix and a **new** CloudFront
distribution — none of these values are stable across a destroy/recreate cycle.
Re-fetch them each time, don't rely on values from a previous session.

## Get the values

```sh
cd aws/terraform
terraform output                                    # anything wired up as an output
terraform output -raw site_bucket_name               # just the value, no quotes
terraform state show aws_cloudfront_distribution.distribution | grep domain_name
```

`terraform state show` prints HCL, not JSON — attribute names are bare
(`domain_name = "d123....cloudfront.net"`), not quoted. `grep '"domain_name"'` won't
match anything; `grep domain_name` will. The distribution has two origins, so this
grep prints three lines: the distribution's own domain, then each S3 origin's.

## Verify the site is up (Step 1)

```sh
curl -I https://<distribution-domain>/                                      # expect 200
curl -I https://<site-bucket-name>.s3.sa-east-1.amazonaws.com/index.html    # expect 403
```

`200` through CloudFront + `403` direct to S3 is the whole point of Step 1: public via
the distribution, genuinely private on its own.

## Verify the movie bucket routing is up (Step 2)

```sh
curl -I https://<distribution-domain>/movie/test.txt                        # expect 200 (unrestricted for now)
curl -I https://<movie-bucket-name>.s3.sa-east-1.amazonaws.com/test.txt    # expect 403
```

The S3 object key must include the `movie/` prefix to match the request path —
CloudFront doesn't strip it. Upload with
`aws s3 cp <file> s3://<movie-bucket-name>/movie/<file>`, not straight to the bucket
root, or you'll get a `403` that looks like a policy failure but is actually just a
missing key (see README's Step 2 gotchas).

## Public access block sanity check

```sh
aws s3api get-public-access-block --bucket <bucket-name>
```

All four booleans should read `true`. Run for both the site and movie buckets.

## Re-upload content after a fresh apply

A brand-new bucket is empty — nothing survives a destroy/recreate cycle.

```sh
echo "hello from serverless-vod" > /tmp/index.html
aws s3 cp /tmp/index.html s3://<site-bucket-name>/index.html

echo "movie placeholder" > /tmp/test.txt
aws s3 cp /tmp/test.txt s3://<movie-bucket-name>/movie/test.txt
```

## Teardown when done for the day

```sh
terraform destroy
```

CloudFront distributions must be **disabled before they can be deleted** — that step
alone commonly takes 2-3+ minutes on its own. Normal, not stuck.
