# The app's public hostnames and the course's DNS zone, in one place. Bootstrap uses them to limit what
# each CI role may change in the zone; each env uses them for its certificate and ExternalDNS. Both read
# this module, so the two can't drift (a mismatch would only show up as AccessDenied during an apply).
#
# The zone, sctp-sandbox.com, belongs to the course: the instructor allows groups to add their own
# records to it. Other groups have records there, so we only ever touch names under our hostnames.
# No resources: values only.

output "zone_id" {
  description = "The course's shared public zone, sctp-sandbox.com"
  value       = "Z00541411T1NGPV97B5C0"
}

output "hostnames" {
  description = "Env => the bank's public hostname in that zone"
  value = {
    staging = "merlion-staging.sctp-sandbox.com"
    prod    = "merlion.sctp-sandbox.com"
  }
}
