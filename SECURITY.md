# VylarisSpace security policy

Thank you for helping to keep VylarisSpace secure.

## Reporting a vulnerability

Please report suspected vulnerabilities **privately** to the owner of this repository, using GitHub's private vulnerability reporting: open the **Security** tab of this repository and choose **Report a vulnerability**.

Please include a detailed description of the vulnerability, a list of the services involved (for example exim or dovecot) and the versions you tested, full steps to reproduce it, and your findings and expected results.

Please do not open a public issue or discuss the problem in public before a fix has been released.

## Supported versions

| Version | Supported          |
| ------- | ------------------ |
| Latest  | :white_check_mark: |

## Update protection

A package guard refuses a `hestia` package that is not a VylarisSpace package (`dpkg -i` and apt). Its limits are listed in [VYLARIS-PACKAGING.md](VYLARIS-PACKAGING.md#154-the-package-guard): servers need the first guarded build, and a foreign package that ships its own `prerm` exiting 0 passes `dpkg -i`. Reports about a way around the guard are welcome through the channel above.

## Qualifying vulnerabilities

### Vulnerabilities we really care about

- Remote command execution
- Code/SQL injection
- Authentication bypass
- Privilege escalation
- Cross-site scripting (XSS)
- Performing limited admin actions without authorization
- CSRF

### Vulnerabilities we accept

- Open redirects
- Password brute-forcing that circumvents rate limiting

## Non-qualifying vulnerabilities

- Theoretical attacks without proof of exploitability
- Attacks that are the result of a third party library should be reported to the library maintainers
- Social engineering
- Reflected file download
- Physical attacks
- Weak SSL/TLS/SSH algorithms or protocols
- Attacks involving physical access to a user’s device, or involving a device or network that’s already seriously compromised (eg man-in-the-middle).
- The user attacks themselves
- anything in `/test/` folder
