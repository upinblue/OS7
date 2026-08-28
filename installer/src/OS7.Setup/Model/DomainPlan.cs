using System.Text.Json.Serialization;

namespace OS7.Setup.Model;

/// <summary>
/// The domain half of the plan — SETUP-PLAN §3 screen 9D, D16, L35.
///
/// IT IS A JOIN THAT HAPPENS DURING THE INSTALL, AND THAT IS THE OPPOSITE OF
/// WHAT THE TPM STEP LEARNED. BUILD-NOTES #69 moved TPM enrolment to first boot
/// because sealing depends on PCR values, and the installer's PCR 7 is not the
/// installed machine's PCR 7 — the same machine measures differently on either
/// side of the reboot. A join depends on the hostname, DNS, the clock and a
/// credential, and all four are the same on both sides. What is NOT the same is
/// the credential: it is in RAM while Setup is running and it must never be
/// written down, so "join later" would mean "persist a domain password", which
/// is the one thing this plan may not do (L25's rule, fourth instance).
///
/// SO THE PASSWORD IS <see cref="JsonIgnore"/>, like the LUKS passphrase, the
/// account password and the Wi-Fi secret before it. It reaches
/// <c>Join-OS7Domain</c> through a keyfile in <c>/run</c> — a tmpfs — that
/// `DomainStep` removes in a `finally`, and it is never in argv, never in the
/// plan file and never in the log.
///
/// THE PREFERRED CREDENTIAL IS NOT A DOMAIN ADMINISTRATOR. A pre-created
/// computer account with a one-time password is what an administrator can hand
/// to whoever is standing in front of the machine; a Domain Admin password
/// typed into a text-mode installer is a password on a screen in a room, and
/// then in somebody's muscle memory. Both are offered because both are real,
/// and which one is meant is decided by whether <see cref="JoinAccount"/> is
/// blank — DERIVED, never a second field, for D14's reason: a field would be a
/// second place for the same answer to be wrong.
/// </summary>
internal sealed class DomainPlan
{
    /// <summary>
    /// Whether this computer joins a domain at all.
    ///
    /// AN EXPLICIT CHOICE, the way `NetworkMethod.None` is one (L23). Screen 9D
    /// records `false` when the domain field is left blank and when the screen
    /// is skipped, so a plan file can tell "nobody asked" from "asked, and the
    /// answer was no".
    /// </summary>
    public bool Join { get; set; }

    /// <summary>
    /// The domain, as DNS spells it — `corp.example.com`.
    ///
    /// Named `Realm` because that is the word for what the credential is checked
    /// against, and in Active Directory the two are one string in two cases: the
    /// Kerberos realm is the upper-case of the DNS domain name, by construction.
    /// Everything on the wire wants the DNS form, so that is what is stored and
    /// what the screen shows; nothing here upper-cases it, because a realm this
    /// code invented is a realm nobody can check against a DC.
    /// </summary>
    public string? Realm { get; set; }

    /// <summary>
    /// The name of the computer account in the directory.
    ///
    /// FIFTEEN CHARACTERS, and it is checked here rather than left to the DC.
    /// A computer's `sAMAccountName` is the name with a `$` appended and is
    /// limited to sixteen characters, which is the NetBIOS name limit seen from
    /// the directory side — so a sixteen-character computer name is refused by
    /// the domain, in the middle of an install, several minutes after the screen
    /// that could have said so. Same argument as `AccountPlan.IsValidUsername`
    /// and `useradd`.
    ///
    /// Screen 9D pre-fills it with the computer name from screen 7, because that
    /// is the right answer nearly always: sssd derives the host principal from
    /// the machine's own name, and a machine whose directory name and hostname
    /// differ is a machine two tools disagree about. It stays editable, because
    /// a hostname may be longer than fifteen characters and the directory's copy
    /// then cannot be the same string.
    /// </summary>
    public string? ComputerName { get; set; }

    /// <summary>
    /// Where the computer account goes, as a distinguished name —
    /// `OU=Linux,OU=Servers,DC=corp,DC=example,DC=com`. Blank is legal and means
    /// the domain's default container, which is what most joins want.
    /// </summary>
    public string? OrganizationalUnit { get; set; }

    /// <summary>
    /// The account whose password authorises the join, or blank.
    ///
    /// BLANK IS THE PREFERRED ANSWER, not the absent one: it means the computer
    /// account has already been created in the directory and the password field
    /// holds its one-time password. Filled in, it names a user allowed to create
    /// computer accounts, and the password field is that user's.
    /// </summary>
    public string? JoinAccount { get; set; }

    /// <summary>
    /// NEVER SERIALISED. L25, the fourth instance in this codebase after the
    /// LUKS passphrase, the account password and the Wi-Fi secret.
    ///
    /// Unlike the Wi-Fi passphrase it does not reach the target at all: the join
    /// consumes it and what lands on the disk is a keytab. `--unattend` takes it
    /// from `--domain-password-file`, a separate artefact with its own handling.
    /// </summary>
    [JsonIgnore]
    public string? Password { get; set; }

    /// <summary>
    /// Which credential this is, DERIVED from <see cref="JoinAccount"/> and from
    /// nothing else — D14's argument applied to a second thing. A field holding
    /// the same answer could disagree with the field the operator typed in, and
    /// the disagreement would only show up as a join that fails for a reason the
    /// screen cannot explain.
    /// </summary>
    [JsonIgnore]
    public bool UsesOneTimePassword => string.IsNullOrWhiteSpace(JoinAccount);

    /// <summary>Whether screen 9D's F4 reached a domain controller, and what it
    /// saw. Recorded rather than required, exactly like
    /// <see cref="NetworkPlan.Verified"/>: a machine may legitimately be built
    /// for a domain that is not reachable from where it is being built, and what
    /// must not happen is that nothing anywhere says so.</summary>
    public bool Verified { get; set; }

    /// <summary>What the test actually saw, for the log.</summary>
    public string? VerifiedDetail { get; set; }

    /// <summary>
    /// Whether the join ACTUALLY HAPPENED, written by `DomainStep` after it has
    /// read the keytab back out of the target.
    ///
    /// It exists because the step is best-effort by design (see `DomainStep`),
    /// and the absence of an error is not evidence — the recurring shape of the
    /// expensive bugs in this repository is a program that reported success
    /// while the thing it was meant to change did not change. Today its only
    /// reader is the plan `CompleteScreen` logs when the install is over; screen
    /// 12 does not yet print a line for it, and that is named in L35 rather than
    /// left to be discovered.
    /// </summary>
    public bool Joined { get; set; }

    /// <summary>What the join left behind, or why there is nothing.</summary>
    public string? JoinedDetail { get; set; }

    /// <summary>The directory's limit on a computer account's name, minus the
    /// `$` that is always appended to it.</summary>
    public const int MaximumComputerName = 15;

    public void Validate(List<string> problems)
    {
        if (!Join)
        {
            // Nothing else is required and nothing else is checked — the same
            // rule as `NetworkMethod.None`. A plan may only be refused for
            // something it could have got right, and "this computer is not in a
            // domain" is the answer for nearly every machine.
            return;
        }

        if (string.IsNullOrWhiteSpace(Realm))
            problems.Add("no domain was named");
        else if (!IsValidDomainName(Realm!))
            problems.Add($"'{Realm}' is not a domain name, like corp.example.com");

        // REQUIRED, not defaulted from the hostname, and the difference matters
        // for `--unattend`: a plan file that says "join" and does not say what
        // this computer is called in the directory is a plan whose answer would
        // have to be invented here. Screen 9D fills the field in from screen 7's
        // answer, so nobody types it twice.
        if (string.IsNullOrWhiteSpace(ComputerName))
            problems.Add("a domain join needs a name for this computer's account");
        else if (!IsValidComputerName(ComputerName!))
            problems.Add($"'{ComputerName}' is not a valid computer account name "
                         + $"(letters, digits and hyphens, at most {MaximumComputerName})");

        if (!string.IsNullOrWhiteSpace(OrganizationalUnit)
            && !OrganizationalUnit!.Contains('='))
            problems.Add($"'{OrganizationalUnit}' is not a distinguished name, "
                         + "like OU=Linux,DC=corp,DC=example,DC=com");

        if (string.IsNullOrEmpty(Password))
            problems.Add(UsesOneTimePassword
                ? "no one-time password was given for the computer account"
                : $"no password was given for {JoinAccount}");

        // THE LAST DEFENCE FOR THE SINGLE-QUOTED POWERSHELL STRING these land
        // in. `DomainStep` builds a `Join-OS7Domain` command line the way
        // `StorageSteps` builds `New-OS7Storage`'s, and a quote inside one of
        // these values would end the string and leave the rest to be executed.
        // The domain and the computer name cannot contain one — their character
        // sets forbid it — but a distinguished name and an account name can, so
        // they are refused HERE, where nothing has been written yet.
        foreach ((string what, string? value) in new[]
                 {
                     ("organizational unit", OrganizationalUnit),
                     ("join account", JoinAccount),
                 })
        {
            if (!string.IsNullOrEmpty(value) && !IsSafeInSingleQuotes(value!))
                problems.Add($"the {what} contains a quote or a control character");
        }
    }

    /// <summary>
    /// A DNS domain name, label by label — RFC 1123's rule, which is the one
    /// `AccountPlan.IsValidHostname` already implements for a single label. It
    /// is reused rather than restated: two copies of one rule is BUILD-NOTES #66
    /// in miniature.
    ///
    /// A SINGLE LABEL IS ALLOWED. Microsoft has discouraged single-label AD
    /// domains for twenty years and they still exist; an installer that cannot
    /// join one is an installer that cannot be used at the sites that have one,
    /// and refusing it here would be Setup inventing a requirement the directory
    /// does not have.
    /// </summary>
    public static bool IsValidDomainName(string s)
    {
        if (s.Length is 0 or > 255) return false;
        string[] labels = s.Split('.');
        return labels.All(AccountPlan.IsValidHostname);
    }

    /// <summary>The computer account's name: a host label, and at most
    /// <see cref="MaximumComputerName"/> characters — see the field.</summary>
    public static bool IsValidComputerName(string s) =>
        s.Length <= MaximumComputerName && AccountPlan.IsValidHostname(s);

    /// <summary>
    /// Whether a value can be carried inside a single-quoted PowerShell string.
    ///
    /// Newlines and NULs are here as well as the quote: `TextBox` refuses
    /// control characters, so an interactive install cannot produce one, and
    /// `--unattend` reads a JSON file that can hold anything at all.
    /// </summary>
    public static bool IsSafeInSingleQuotes(string s) =>
        !s.Contains('\'') && s.All(c => !char.IsControl(c));
}
