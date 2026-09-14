#!/usr/bin/env python3
"""Validate public build configuration without printing account credentials."""
import os
import re
import sys
from urllib.parse import urlsplit

def valid(values):
    endpoint, topic, number, client = values
    try:
        url = urlsplit(endpoint)
        endpoint_ok = (url.scheme == "https" and url.hostname and not url.username and not url.password
                       and url.port in (None, 443) and url.path in ("", "/") and not url.query and not url.fragment)
    except ValueError:
        return False
    return bool(endpoint_ok and re.fullmatch(r"projects/[a-z][a-z0-9-]{4,29}/topics/[A-Za-z][A-Za-z0-9._~-]{2,254}", topic)
                and re.fullmatch(r"[0-9]{6,20}", number) and client.startswith(number + "-")
                and client.endswith(".apps.googleusercontent.com"))

if __name__ == "__main__":
    values = [os.environ.get(key, "") for key in ("EMBLEM_GMAIL_PUSH_ENDPOINT", "EMBLEM_GMAIL_PUBSUB_TOPIC", "EMBLEM_GOOGLE_PROJECT_NUMBER", "EMBLEM_GOOGLE_CLIENT_ID")]
    if not valid(values):
        print("Invalid or incomplete Gmail Push configuration. Set endpoint, topic, project number and matching desktop client ID.", file=sys.stderr)
        sys.exit(4)
    print("GMAIL_PUSH_CONFIG=VALID")
