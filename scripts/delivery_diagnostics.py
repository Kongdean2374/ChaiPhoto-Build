"""Emit structured allowlisted signals, never excerpts of a private delivery log."""
import argparse
import json
from pathlib import Path
import re

MAX_LOG_BYTES = 8 * 1024 * 1024
DOMAINS = (
    "IDEDistributionErrorDomain", "IDEDistributionPipelineErrorDomain",
    "IDEDistributionSigningAssetsStepErrorDomain", "IDEProvisioningErrorDomain",
    "DVTPortalResponseErrorDomain", "ITunesConnectionOperationErrorDomain",
    "DVTITunesSoftwareServiceFoundationErrorDomain", "ITunesTransporterErrorDomain",
    "DeveloperAPIServiceErrorDomain", "DVTServicesSessionErrorDomain",
    "NSURLErrorDomain", "NSCocoaErrorDomain", "NSOSStatusErrorDomain", "ASDErrorDomain",
)
SIGNALS = {
    "key-file": r"(?:private key|authentication key|AuthKey)[^\n]{0,100}(?:not found|missing|cannot|could not)|(?:cannot|could not|unable to)[^\n]{0,60}(?:private key|authentication key)",
    "authentication": r"authentication (?:failed|credentials|error)|not authenticated|(?:unable|failed) to authenticate|no accounts|invalid (?:JWT|token)|token (?:expired|is invalid)",
    "authorization": r"permission (?:denied|error)|not authorized|not permitted|insufficient (?:role|permission)",
    "signing": r"no signing certificate|invalid signature|code.?sign(?:ing)? (?:failed|error)|cloud signing permission",
    "provisioning": r"no profiles? for|provisioning profile[^\n]{0,100}(?:invalid|missing|expired|doesn.t|not)|requires a provisioning profile",
    "duplicate-build": r"already (?:been )?uploaded|redundant binary|duplicate (?:build|binary)|bundle version[^\n]{0,100}(?:higher|greater)",
    "agreement": r"(?:agreement|contract)[^\n]{0,100}(?:expired|pending|not accepted|must be accepted)",
    "network": r"timed? out|connection (?:failed|reset|refused)|network (?:error|unreachable)|could not resolve host",
    "export-options": r"exportoptions[^\n]{0,100}(?:invalid|error)|(?:invalid|unsupported)[^\n]{0,80}(?:distribution method|export option)",
    "validation": r"validation failed|asset validation|invalid binary",
}


def summarize(text, stage, exit_code):
    if stage not in {"archive", "export-upload"} or type(exit_code) is not int or not 0 <= exit_code <= 255:
        raise ValueError("Invalid diagnostic input")
    domain_codes = set()
    for domain in DOMAINS:
        for match in re.finditer(
            r"\b" + re.escape(domain) + r"\b(?:\s+|[\"']\s*[,;]?\s*)Code\s*=\s*(-?\d{1,6})(?!\d)", text
        ):
            domain_codes.add((domain, int(match[1])))
    itms = sorted(set(re.findall(r"\bITMS-[0-9]{5}\b", text)))[:20]
    statuses = sorted({int(m[1]) for m in re.finditer(
        r"\b(?:HTTP(?:/[0-9.]+)?\s+|HTTP(?:\s+status(?:\s+code)?)?\s*[=:]\s*|statusCode\s*[=:]\s*)([45][0-9]{2})(?!\d)",
        text, re.I,
    )})[:20]
    return {
        "stage": stage, "tool": "xcodebuild", "exit_code": exit_code,
        "itms_codes": itms,
        "domain_codes": [{"domain": d, "code": c} for d, c in sorted(domain_codes)[:20]],
        "http_statuses": statuses,
        "signals": [name for name, pattern in SIGNALS.items() if re.search(pattern, text, re.I)],
        "raw_log_published": False,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--stage", required=True, choices=["archive", "export-upload"])
    parser.add_argument("--exit-code", required=True, type=int)
    parser.add_argument("--log", required=True, type=Path)
    args = parser.parse_args()
    try:
        # Read the tail: Xcode puts delivery errors at the end of potentially large logs.
        with args.log.open("rb") as stream:
            size = stream.seek(0, 2)
            stream.seek(max(0, size - MAX_LOG_BYTES))
            text = stream.read(MAX_LOG_BYTES).decode("utf-8", errors="replace")
        report = summarize(text, args.stage, args.exit_code)
        report["log_readable"] = True
    except (OSError, ValueError):
        report = summarize("", args.stage, args.exit_code)
        report["log_readable"] = False
    print("::error::Delivery failed; only allowlisted diagnostic signals follow.")
    print(json.dumps(report, sort_keys=True))


if __name__ == "__main__":
    main()
