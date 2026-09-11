#!/usr/bin/env bash
#
# pack-name-pattern.sh - shared pack-name validation regex for new-pack.sh
# and validate-pack.sh. Meant to be sourced, not executed.
#
# This must match the `name` pattern in schema/v1/manifest.schema.json.
# Bash regex syntax can't be shared directly with JSON Schema, so that copy
# has to be kept in sync by hand if this one ever changes - but the two
# bash copies (new-pack.sh, validate-pack.sh) no longer can drift from
# each other, which was the reachable half of the duplication.
#
OPF_NAME_PATTERN='^[a-z0-9]([a-z0-9._-]*[a-z0-9])?$'
