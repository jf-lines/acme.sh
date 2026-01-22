#!/usr/bin/env sh

# shellcheck disable=SC2034
dns_opusdns_info='OpusDNS.com
Site: OpusDNS.com
Docs: github.com/acmesh-official/acme.sh/wiki/dnsapi#dns_opusdns
Options:
 OPUSDNS_API_Key API Key. Can be created at https://dashboard.opusdns.com/settings/api-keys
 OPUSDNS_API_Endpoint API Endpoint URL. Default "https://api.opusdns.com". Optional.
 OPUSDNS_TTL TTL for DNS challenge records in seconds. Default "60". Optional.
 OPUSDNS_Polling_Interval DNS propagation check interval in seconds. Default "6". Optional.
 OPUSDNS_Propagation_Timeout Maximum time to wait for DNS propagation in seconds. Default "120". Optional.
Issues: github.com/acmesh-official/acme.sh/issues/XXXX
Author: OpusDNS Team <https://github.com/opusdns>
'

OPUSDNS_API_Endpoint_Default="https://api.opusdns.com"
OPUSDNS_TTL_Default=60
OPUSDNS_Polling_Interval_Default=6
OPUSDNS_Propagation_Timeout_Default=120

######## Public functions ###########

# Add DNS TXT record
# Usage: dns_opusdns_add _acme-challenge.example.com "token_value"
dns_opusdns_add() {
  fulldomain=$1
  txtvalue=$2

  _info "Using OpusDNS DNS API"
  _debug fulldomain "$fulldomain"
  _debug txtvalue "$txtvalue"

  # Load and validate credentials
  OPUSDNS_API_Key="${OPUSDNS_API_Key:-$(_readaccountconf_mutable OPUSDNS_API_Key)}"
  if [ -z "$OPUSDNS_API_Key" ]; then
    _err "OPUSDNS_API_Key not set. Please set it and try again."
    _err "You can create an API key at your OpusDNS dashboard."
    return 1
  fi

  # Save credentials for future use
  _saveaccountconf_mutable OPUSDNS_API_Key "$OPUSDNS_API_Key"

  # Load optional configuration
  OPUSDNS_API_Endpoint="${OPUSDNS_API_Endpoint:-$(_readaccountconf_mutable OPUSDNS_API_Endpoint)}"
  if [ -z "$OPUSDNS_API_Endpoint" ]; then
    OPUSDNS_API_Endpoint="$OPUSDNS_API_Endpoint_Default"
  fi
  _saveaccountconf_mutable OPUSDNS_API_Endpoint "$OPUSDNS_API_Endpoint"

  OPUSDNS_TTL="${OPUSDNS_TTL:-$(_readaccountconf_mutable OPUSDNS_TTL)}"
  if [ -z "$OPUSDNS_TTL" ]; then
    OPUSDNS_TTL="$OPUSDNS_TTL_Default"
  fi
  _saveaccountconf_mutable OPUSDNS_TTL "$OPUSDNS_TTL"

  OPUSDNS_Polling_Interval="${OPUSDNS_Polling_Interval:-$OPUSDNS_Polling_Interval_Default}"
  OPUSDNS_Propagation_Timeout="${OPUSDNS_Propagation_Timeout:-$OPUSDNS_Propagation_Timeout_Default}"

  _debug "API Endpoint: $OPUSDNS_API_Endpoint"
  _debug "TTL: $OPUSDNS_TTL"

  # Detect zone from FQDN
  if ! _get_zone "$fulldomain"; then
    _err "Failed to detect zone for domain: $fulldomain"
    return 1
  fi

  _info "Detected zone: $_zone"
  _debug "Record name: $_record_name"

  # Add the TXT record
  if ! _opusdns_add_record "$_zone" "$_record_name" "$txtvalue"; then
    _err "Failed to add TXT record"
    return 1
  fi

  _info "TXT record added successfully"

  # Wait for DNS propagation
  if ! _opusdns_wait_for_propagation "$fulldomain" "$txtvalue"; then
    _err "Warning: DNS record may not have propagated yet"
    _err "Certificate issuance may fail. Please check your DNS configuration."
    # Don't fail here - let ACME client decide
  fi

  return 0
}

# Remove DNS TXT record
# Usage: dns_opusdns_rm _acme-challenge.example.com "token_value"
dns_opusdns_rm() {
  fulldomain=$1
  txtvalue=$2

  _info "Removing OpusDNS DNS record"
  _debug fulldomain "$fulldomain"
  _debug txtvalue "$txtvalue"

  # Load credentials
  OPUSDNS_API_Key="${OPUSDNS_API_Key:-$(_readaccountconf_mutable OPUSDNS_API_Key)}"
  OPUSDNS_API_Endpoint="${OPUSDNS_API_Endpoint:-$(_readaccountconf_mutable OPUSDNS_API_Endpoint)}"
  OPUSDNS_TTL="${OPUSDNS_TTL:-$(_readaccountconf_mutable OPUSDNS_TTL)}"
  
  if [ -z "$OPUSDNS_API_Endpoint" ]; then
    OPUSDNS_API_Endpoint="$OPUSDNS_API_Endpoint_Default"
  fi

  if [ -z "$OPUSDNS_TTL" ]; then
    OPUSDNS_TTL="$OPUSDNS_TTL_Default"
  fi

  if [ -z "$OPUSDNS_API_Key" ]; then
    _err "OPUSDNS_API_Key not found"
    return 1
  fi

  # Detect zone from FQDN
  if ! _get_zone "$fulldomain"; then
    _err "Failed to detect zone for domain: $fulldomain"
    # Don't fail cleanup - best effort
    return 0
  fi

  _info "Detected zone: $_zone"
  _debug "Record name: $_record_name"

  # Remove the TXT record (need to pass txtvalue)
  if ! _opusdns_remove_record "$_zone" "$_record_name" "$txtvalue"; then
    _err "Warning: Failed to remove TXT record (this is usually not critical)"
    # Don't fail cleanup - best effort
    return 0
  fi

  _info "TXT record removed successfully"
  return 0
}

######## Private functions ###########

# Detect zone from FQDN by querying OpusDNS API
# Sets global variables: _zone, _record_name
_get_zone() {
  domain=$1
  _debug "Detecting zone for: $domain"

  # Remove trailing dot if present
  domain=$(echo "$domain" | sed 's/\.$//')

  # Get all zones from OpusDNS with pagination support
  export _H1="X-Api-Key: $OPUSDNS_API_Key"
  
  zones=""
  page=1
  has_more=1
  
  while [ $has_more -eq 1 ]; do
    _debug2 "Fetching zones page $page"
    response=$(_get "$OPUSDNS_API_Endpoint/v1/dns?page=$page&page_size=100")
    if [ $? -ne 0 ]; then
      _err "Failed to query zones from OpusDNS API (page $page)"
      _debug "Response: $response"
      return 1
    fi

    _debug2 "Zones response (page $page): $response"

    # Extract zone names from this page (try jq first, fallback to grep/sed)
    if _exists jq; then
      page_zones=$(echo "$response" | jq -r '.results[].name' 2>/dev/null | sed 's/\.$//')
      has_next=$(echo "$response" | jq -r '.has_next_page // false' 2>/dev/null)
    else
      # Fallback: extract zone names using grep/sed
      # Note: This simple parser does not handle escaped quotes in zone names.
      # Zone names with escaped quotes are extremely rare and would require jq.
      page_zones=$(echo "$response" | grep -oE '"name"[[:space:]]*:[[:space:]]*"[^"\\]*"' | sed 's/"name"[[:space:]]*:[[:space:]]*"\([^"\\]*\)"/\1/' | sed 's/\.$//')
      has_next=$(echo "$response" | grep -oE '"has_next_page"[[:space:]]*:[[:space:]]*(true|false)' | grep -o 'true\|false')
    fi
    
    # Append zones from this page
    if [ -n "$page_zones" ]; then
      if [ -z "$zones" ]; then
        zones="$page_zones"
      else
        zones="$zones
$page_zones"
      fi
    fi
    
    # Check if there are more pages
    if [ "$has_next" = "true" ]; then
      page=$((page + 1))
    else
      has_more=0
    fi
  done

  if [ -z "$zones" ]; then
    _err "No zones found in OpusDNS account"
    _debug "API Response: $response"
    return 1
  fi

  _debug2 "Available zones (all pages): $zones"

  # Find longest matching zone
  _zone=""
  _zone_length=0

  for zone in $zones; do
    zone_with_dot="${zone}."
    if _endswith "$domain." "$zone_with_dot"; then
      zone_length=${#zone}
      if [ $zone_length -gt $_zone_length ]; then
        _zone="$zone"
        _zone_length=$zone_length
      fi
    fi
  done

  if [ -z "$_zone" ]; then
    _err "No matching zone found for domain: $domain"
    _err "Available zones: $zones"
    return 1
  fi

  # Calculate record name (subdomain part)
  # Use parameter expansion instead of sed to avoid regex metacharacter issues
  _record_name="${domain%.${_zone}}"
  # Handle case where domain equals zone (remove trailing dot if present)
  if [ "$_record_name" = "$domain" ]; then
    _record_name="${domain%${_zone}}"
    _record_name="${_record_name%.}"
  fi
  
  if [ -z "$_record_name" ]; then
    _record_name="@"
  fi

  return 0
}

# Add TXT record using OpusDNS API
_opusdns_add_record() {
  zone=$1
  record_name=$2
  txtvalue=$3

  _debug "Adding TXT record: $record_name.$zone = $txtvalue"

  # Escape all JSON special characters in txtvalue
  # Order matters: escape backslashes first, then other characters
  escaped_value=$(printf '%s' "$txtvalue" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g' | sed ':a;N;$!ba;s/\n/\\n/g')

  # Build JSON payload
  # Note: TXT records need quotes around the value in rdata
  json_payload="{\"ops\":[{\"op\":\"upsert\",\"record\":{\"name\":\"$record_name\",\"type\":\"TXT\",\"ttl\":$OPUSDNS_TTL,\"rdata\":\"\\\"$escaped_value\\\"\"}}]}"

  _debug2 "JSON payload: $json_payload"

  # Send PATCH request
  export _H1="X-Api-Key: $OPUSDNS_API_Key"
  export _H2="Content-Type: application/json"

  response=$(_post "$json_payload" "$OPUSDNS_API_Endpoint/v1/dns/$zone/records" "" "PATCH")
  status=$?

  _debug2 "API Response: $response"

  if [ $status -ne 0 ]; then
    _err "Failed to add TXT record"
    _err "API Response: $response"
    return 1
  fi

  # Check for error in response (OpusDNS returns JSON error even on failure)
  # Use anchored pattern to avoid matching field names like "error_count"
  if echo "$response" | grep -q '"error":'; then
    _err "API returned error: $response"
    return 1
  fi

  return 0
}

# Remove TXT record using OpusDNS API
_opusdns_remove_record() {
  zone=$1
  record_name=$2
  txtvalue=$3

  _debug "Removing TXT record: $record_name.$zone = $txtvalue"

  # Escape all JSON special characters in txtvalue (same as add)
  escaped_value=$(printf '%s' "$txtvalue" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g' | sed ':a;N;$!ba;s/\n/\\n/g')

  # Build JSON payload for removal - needs complete record specification
  json_payload="{\"ops\":[{\"op\":\"remove\",\"record\":{\"name\":\"$record_name\",\"type\":\"TXT\",\"ttl\":$OPUSDNS_TTL,\"rdata\":\"\\\"$escaped_value\\\"\"}}]}"

  _debug2 "JSON payload: $json_payload"

  # Send PATCH request
  export _H1="X-Api-Key: $OPUSDNS_API_Key"
  export _H2="Content-Type: application/json"

  response=$(_post "$json_payload" "$OPUSDNS_API_Endpoint/v1/dns/$zone/records" "" "PATCH")
  status=$?

  _debug2 "API Response: $response"

  if [ $status -ne 0 ]; then
    _err "Failed to remove TXT record"
    _err "API Response: $response"
    return 1
  fi

  return 0
}

# Wait for DNS propagation by checking OpusDNS authoritative nameservers
_opusdns_wait_for_propagation() {
  fulldomain=$1
  txtvalue=$2

  _info "Waiting for DNS propagation to authoritative nameservers (max ${OPUSDNS_Propagation_Timeout}s)..."

  max_attempts=$((OPUSDNS_Propagation_Timeout / OPUSDNS_Polling_Interval))
  # Ensure at least one attempt even if interval > timeout
  if [ "$max_attempts" -lt 1 ]; then
    max_attempts=1
  fi
  attempt=1

  # OpusDNS authoritative nameservers
  nameservers="ns1.opusdns.com ns2.opusdns.net"

  while [ $attempt -le $max_attempts ]; do
    _debug "Propagation check attempt $attempt/$max_attempts"

    all_propagated=1
    
    # Check all OpusDNS authoritative nameservers
    for ns in $nameservers; do
      if _exists dig; then
        result=$(dig @$ns +short "$fulldomain" TXT 2>/dev/null | tr -d '"')
      elif _exists nslookup; then
        result=$(nslookup -type=TXT "$fulldomain" $ns 2>/dev/null | grep -A1 "text =" | tail -n1 | tr -d '"' | sed 's/^[[:space:]]*//')
      else
        _err "Neither dig nor nslookup found. Cannot verify DNS propagation."
        return 1
      fi

      _debug2 "DNS query result from $ns: $result"

      if ! echo "$result" | grep -qF "$txtvalue"; then
        _debug "Record not yet on $ns"
        all_propagated=0
      else
        _debug "Record found on $ns ✓"
      fi
    done

    if [ $all_propagated -eq 1 ]; then
      _info "DNS record propagated to all OpusDNS nameservers!"
      return 0
    fi

    if [ $attempt -lt $max_attempts ]; then
      _debug "Record not propagated to all nameservers yet, waiting ${OPUSDNS_Polling_Interval}s..."
      sleep "$OPUSDNS_Polling_Interval"
    fi

    attempt=$((attempt + 1))
  done

  _err "DNS record did not propagate to all nameservers within ${OPUSDNS_Propagation_Timeout} seconds"
  return 1
}
