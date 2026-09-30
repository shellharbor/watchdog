validate_http_transport() {
    local expression="$1" description="$2" value value_type field cert_type key_type
    local username_type password_type

    value_type="$(yaml_read "${expression}.tls | type")"
    if [[ "$value_type" != '!!null' ]]; then
        [[ "$value_type" == '!!map' ]] || die "${description}.tls must be a map."
        cert_type="$(yaml_read "${expression}.tls.client_cert_file | type")"
        key_type="$(yaml_read "${expression}.tls.client_key_file | type")"
        [[ "$cert_type" == '!!null' && "$key_type" == '!!null' ]] ||
            [[ "$cert_type" != '!!null' && "$key_type" != '!!null' ]] ||
            die "${description}.tls.client_cert_file and ${description}.tls.client_key_file must be set together."
        for field in ca_cert_file client_cert_file client_key_file; do
            value_type="$(yaml_read "${expression}.tls.${field} | type")"
            [[ "$value_type" == '!!null' ]] && continue
            validate_string "${expression}.tls.${field}" "${description}.tls.${field}"
            value="$(yaml_read "${expression}.tls.${field}")"
            [[ "$value" == /* ]] || die "${description}.tls.${field} must be an absolute path."
            [[ -f "$value" && -r "$value" ]] || die "${description}.tls.${field} must be a readable regular file."
        done
    fi

    value_type="$(yaml_read "${expression}.proxy | type")"
    [[ "$value_type" == '!!null' ]] && return 0
    [[ "$value_type" == '!!map' ]] || die "${description}.proxy must be a map."
    validate_string "${expression}.proxy.url" "${description}.proxy.url"
    value="$(yaml_read "${expression}.proxy.url")"
    [[ "$value" =~ ^https?://[^@[:space:]]+$ ]] ||
        die "${description}.proxy.url must be an HTTP(S) URL without credentials or spaces."

    username_type="$(yaml_read "${expression}.proxy.username_env | type")"
    password_type="$(yaml_read "${expression}.proxy.password_env | type")"
    [[ "$username_type" == '!!null' || "$username_type" == '!!str' ]] ||
        die "${description}.proxy.username_env must be a string."
    [[ "$password_type" == '!!null' || "$password_type" == '!!str' ]] ||
        die "${description}.proxy.password_env must be a string."
    [[ "$username_type" == '!!null' && "$password_type" == '!!null' ]] ||
        [[ "$username_type" != '!!null' && "$password_type" != '!!null' ]] ||
        die "${description}.proxy.username_env and ${description}.proxy.password_env must be set together."
    for field in username_env password_env; do
        value_type="$(yaml_read "${expression}.proxy.${field} | type")"
        [[ "$value_type" == '!!null' ]] && continue
        validate_string "${expression}.proxy.${field}" "${description}.proxy.${field}"
        value="$(yaml_read "${expression}.proxy.${field}")"
        [[ "$value" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "${description}.proxy.${field} is not a valid environment variable name."
    done
}
