# IPAFFS routing checker

Checks whether IPAFFS traffic is being served by the Classic stack or the AKS stack while Azure Front Door routing changes are being made.

See the Confluence page for more information: [Azure Front Door Routing Checker](https://eaflood.atlassian.net/wiki/spaces/IM/pages/6553698354/Azure+Front+Door+Routing+Checker)

## Script

```bash
./routing-check.sh -e ENV [-w SECONDS] [-c CHECKS]
```

Run from this directory, or call the script by its full path from the repository root:

```bash
scripts/tools/routing-checker/routing-check.sh -e tst
```

## Requirements

- Bash 4 or newer
- `curl`
- `nslookup`

## Options

Option | Required | Description
------ |----------| -----------
`-e`   | Yes      | Environment to check. Valid values are `dev`, `tst`, `pre`, `prd`.
`-w`   | No       | Wait time between checks in seconds. Default is `5`. Use `0` for no wait.
`-c`   | No       | Number of checks to perform before stopping. One check sends one B2C request and one B2B request.

If `-c` is not provided, the script runs until `q` or `Q` is pressed.

## Examples

Run continuously against TST:

```bash
scripts/tools/routing-checker/routing-check.sh -e tst
```

Run 100 TST checks with no wait:

```bash
scripts/tools/routing-checker/routing-check.sh -e tst -w 0 -c 100
```

Run 50 TST checks with a 2 second wait between checks:

```bash
scripts/tools/routing-checker/routing-check.sh -e tst -w 2 -c 50
```

## Output

The script prints DNS resolution for the B2C and B2B domains before making requests.

Each request is logged with the URL type, HTTP status and detected stack:

- `Classic` means the Location header matched the expected Classic prefix.
- `AKS` means the Location header matched the expected AKS redirect prefix.
- `Unknown` means the Location header did not match an expected prefix.
- `Errors` means the response was not a `302` or `303`.

For AKS responses, the script also validates the expected encoded `login_url` value.

When the script stops, it prints response totals, stack percentages, error counts and validation failure counts.
