using System.Net;
using System.Net.Sockets;
using System.Text;
using OS7.Setup.Diagnostics;
using OS7.Setup.Model;

namespace OS7.Setup.Steps;

/// <summary>
/// Asking, from the LIVE environment, whether there is a domain over there.
///
/// The same division as `NetworkProbe`: screen 9D's F4 answers a question about
/// this network, now, in front of the person who typed the name — after the
/// reboot a machine that cannot find its domain is a site visit, and by then
/// nobody is holding the credential any more.
///
/// WHAT IT PROVES IS REACHABILITY AND NOTHING ELSE, and the screen says so
/// where the operator is looking. A DC that answers on 636 can still refuse the
/// credential, refuse the computer account name, or refuse the clock — the join
/// itself is the only proof of a join. What this catches is the failure that is
/// both the commonest and the most invisible: the machine's DNS does not know
/// the domain, which presents to every AD client as "the domain could not be
/// contacted" with no clue as to which of the four things went wrong.
/// </summary>
internal static class DomainProbe
{
    /// <summary>
    /// The tool the join runs, and the reason screen 9D can be absent.
    ///
    /// `Join-OS7Domain` shells out to `adcli`, which is NOT on any ISO this
    /// repository has built: measured 2026-08-27 against the shipped manifest
    /// `out/OS7-1.0.0.116-amd64.packages.manifest` (1 491 packages) — `adcli`,
    /// `sssd-tools`, `krb5-user` and `realmd` are all absent, while `sssd`,
    /// `sssd-ad`, `ldap-utils`, `libsasl2-modules-gssapi-mit` and
    /// `bind9-dnsutils` are present because live-build's `--mode ubuntu` desktop
    /// task brought them. There is no arm64 manifest in `out/` at all, so that
    /// half is an inference and not a measurement.
    ///
    /// So on every medium built so far this returns "adcli", screen 9D is
    /// skipped, and the plan records that nobody was asked (L35). Offering a
    /// screen whose step cannot run would be worse than not offering it — the
    /// same argument `ModeScreen.Applies` makes about a desktop that is not on
    /// the medium.
    ///
    /// It asks the LIVE medium, and that is the correct question for the same
    /// narrow reason `NetworkProbe.LiveRenderer` gives: this is where the join
    /// runs. Whether the TARGET can use the result is a different question with
    /// a different answer, and `DomainStep` asks it inside the chroot.
    /// </summary>
    public static string? MissingTool
    {
        get
        {
            foreach (string dir in new[] { "/usr/sbin", "/usr/bin", "/sbin", "/bin" })
                if (File.Exists($"{dir}/adcli")) return null;
            return "adcli";
        }
    }

    /// <summary>How long one connection attempt is given. Four of them at worst,
    /// so the screen can stand still for eight seconds — which is why 9D shows
    /// "Testing …" on a painted frame before this runs, the way screen 9W does
    /// with its scan.</summary>
    private const int TimeoutSeconds = 2;

    /// <summary>
    /// Resolve the domain and see whether anything answers.
    ///
    /// THE DOMAIN NAME ITSELF IS THE LOOKUP, not `_ldap._tcp.dc._msdcs.<domain>`,
    /// and that is a deliberate limitation rather than an oversight. Every
    /// domain controller registers an A record for the domain name as well as
    /// its SRV records, so this finds a DC wherever an AD client would find one,
    /// and it needs nothing but the resolver .NET already has. An SRV query
    /// would need `dig` — `bind9-dnsutils`, which is on amd64 by accident and
    /// absent from arm64 by construction — or a hand-rolled DNS packet. The
    /// consequence: this cannot tell "the domain does not resolve" from "the
    /// domain resolves and the SRV records are missing", and the second is a
    /// real, if rarer, way for a join to fail.
    /// </summary>
    public static (bool Ok, string Detail) Test(DomainPlan plan)
    {
        plan.Verified = false;
        plan.VerifiedDetail = null;

        if (!plan.Join || string.IsNullOrWhiteSpace(plan.Realm))
            return (false, "There is nothing to test: no domain was typed.");

        string realm = plan.Realm!;
        IPAddress[] addresses;
        try
        {
            addresses = Dns.GetHostAddresses(realm);
        }
        catch (Exception ex)
        {
            // The commonest join failure there is, said as itself. The resolver
            // is the live system's, which screen 9 has already configured and
            // which its own F4 has already tested.
            Log.Warn($"domain test: {realm} does not resolve: {ex.Message}");
            return (false, $"{realm} does not resolve. Check the DNS servers on screen 9.");
        }
        if (addresses.Length == 0)
            return (false, $"{realm} resolves to no address at all.");

        // Two addresses at most: a domain of any size answers this on the first
        // one, and a screen that stands still for a minute is a screen somebody
        // decides has hung.
        foreach (IPAddress ip in addresses.Take(2))
        {
            // 636 FIRST, because LDAPS is what OS/7 uses and because a DC
            // hardened the way Microsoft's ADV190023 guidance asks refuses a
            // simple bind on 389 outright. 389 is still tried, and reported as
            // itself, so an operator can see the difference between "no domain
            // controller here" and "no LDAPS here".
            foreach (int port in new[] { 636, 389 })
            {
                if (!Answers(ip, port)) continue;
                string what = port == 636 ? "LDAPS" : "LDAP";
                plan.Verified = true;
                plan.VerifiedDetail = $"{ip} answers on {port} ({what})";
                Log.Info($"domain test: {realm} is {ip}, {port}/tcp answered");
                return (true, $"{realm} is {ip} and answers on {port}. The domain is reachable.");
            }
        }

        Log.Warn($"domain test: {realm} resolved to {addresses.Length} address(es), "
                 + "none answering on 636 or 389");
        return (false, $"{realm} resolves, but nothing answered on 636 or 389.");
    }

    /// <summary>
    /// One TCP connection, with a deadline.
    ///
    /// A CONNECTION AND NOT A PING: ICMP is filtered on most of the networks
    /// this will run on, and a domain controller that answers a ping while its
    /// directory is down is exactly the false green `ad-dc-entrypoint.sh`
    /// warns about from the other side — smbd binds 389 before the directory is
    /// loaded. This is one step better than a ping and one step short of a bind,
    /// and the screen says which of the three it is.
    /// </summary>
    private static bool Answers(IPAddress ip, int port)
    {
        try
        {
            using var client = new TcpClient(ip.AddressFamily);
            Task connecting = client.ConnectAsync(ip, port);
            return connecting.Wait(TimeSpan.FromSeconds(TimeoutSeconds))
                   && client.Connected;
        }
        catch (Exception ex)
        {
            // Refused, unreachable, or a deadline that expired inside the
            // socket: all of them are "no" here, and the log carries which.
            Log.Info($"domain test: {ip}:{port} — {ex.GetType().Name}");
            return false;
        }
    }
}

// ---------------------------------------------------------------------------

/// <summary>
/// Joining the domain, from inside the install — SETUP-PLAN D16, L35.
///
/// THE ROOT IS A PARAMETER, like every other step here: `Update-OS7` runs this
/// sequence against a cloned boot environment mounted somewhere else
/// (RELEASE-AND-UPDATE-PLAN §4.2), and a step that reached for
/// `StorageSteps.Target` would be a step the update path cannot use.
///
/// IT IS LAST BEFORE THE LOG IS SAVED, and that position is an argument rather
/// than a leftover. A join creates an object in somebody else's directory —
/// the one thing this installer does that `Executor`'s rollback cannot undo,
/// because the rollback destroys pools and has no credential to delete a
/// computer account with. Putting the join after the bootloader means the
/// machine is finished before the directory is touched: everything that can
/// still fail has already failed, so a rolled-back install leaves no orphaned
/// computer account behind. It must equally be after `NetworkStep`, which is
/// what gives it a network at all, and before `InstallLogStep`, so its proof is
/// in the record. All three bounds are asserted in `--self-test` rather than
/// commented, because a reorder has no other symptom.
///
/// THE WORK IS `Join-OS7Domain`'s, NOT THIS FILE'S. `powershell/OS7` owns the
/// join for the same reason it owns `New-OS7Storage`: an operator joining a
/// running machine and Setup joining one during an install must do the same
/// thing, and two implementations of one sequence is BUILD-NOTES #66 with a
/// domain on the end of it. What this step owns is the credential's lifetime,
/// the ordering, and the part that cannot be delegated — asking the target
/// afterwards whether any of it happened.
///
/// AND IT IS BEST EFFORT, DELIBERATELY, the way `TpmEnrolStep` is. A wrong
/// password, a clock five minutes out or a DC that has gone away must not
/// destroy an install that is otherwise complete: the machine boots, the
/// account works, and `Join-OS7Domain` — the same cmdlet, the other caller —
/// is there to be run again. What must not happen is that this is quiet, so the
/// failure is logged as an error, `DomainPlan.Joined` records it as data, and
/// L35 names the one gap left: screen 12 does not yet print it.
/// </summary>
internal sealed class DomainStep : IStep
{
    private readonly InstallPlan _plan;
    private readonly TargetRoot _t;

    public DomainStep(InstallPlan plan, TargetRoot t) { _plan = plan; _t = t; }

    /// <summary>
    /// The keyfile, in `/run`, which is a tmpfs — the password never touches a
    /// disk, and it is removed in a `finally` whatever happens. Exactly
    /// `LuksStep`'s arrangement for the LUKS passphrase, for exactly its reason:
    /// a secret on a command line is a secret in `ps` output on a machine that
    /// may have somebody watching over the operator's shoulder, and this is a
    /// domain credential rather than one machine's.
    /// </summary>
    public const string KeyFile = "/run/os7-setup-domain.key";

    public string Describe => _plan.Domain.Join
        ? $"Joining {_plan.Domain.Realm}"
        : "Not joining a domain";

    /// <summary>A `pwsh` start, `adcli`'s round trip to a DC, and one chroot.
    /// An estimate, like every weight here, and correctable from any install
    /// log's "step done: … after N s".</summary>
    public int Weight => 3;

    public void Run(Executor x)
    {
        DomainPlan d = _plan.Domain;
        if (!d.Join)
        {
            // An explicit choice (D16), logged as one — the same treatment
            // `NetworkStep` gives a machine chosen to have no network. Nothing
            // is written, nothing is enabled, and the plan says who decided.
            Log.Info("domain: none was chosen; this computer is not joined");
            return;
        }

        try
        {
            // THE RESULT IS WRITTEN INSIDE, not here. `ProveUsable` records
            // "joined, and this computer cannot use it", which is a third
            // answer rather than a worse spelling of the first, and a caller
            // that wrote the success sentence after the call overwrote it.
            Join(x, d);
        }
        catch (StepException ex)
        {
            // LOUD, AND THEN ON WITH THE INSTALL. See the class comment: the
            // machine is already complete, and a domain join is the one thing
            // here that can be done again afterwards without reinstalling.
            d.Joined = false;
            d.JoinedDetail = ex.Message;
            Log.Error($"domain: {d.Realm} was NOT joined — {ex.Message}");
            Log.Error($"domain: {ex.Command}");
            if (ex.Output.Length > 0) Log.Error($"domain: {ex.Output.ReplaceLineEndings(" | ")}");
            Log.Warn("domain: the machine is installed and unjoined. Run Join-OS7Domain "
                     + "on it once it has booted.");
        }
        catch (Exception ex)
        {
            // EVERY exception and not only `StepException`, because what is on
            // the other side of this method is `Executor.Run`'s catch and its
            // rollback is a `zpool destroy` — on an install that is complete
            // through the bootloader. `File.WriteAllBytes` and
            // `File.SetUnixFileMode` on the keyfile throw `IOException` and
            // `UnauthorizedAccessException`, neither of which is a
            // `StepException`, and this class's whole argument is that a failed
            // join must not destroy an install. The TYPE is logged: best effort
            // must not also mean that nobody finds out what happened.
            d.Joined = false;
            d.JoinedDetail = $"{ex.GetType().Name}: {ex.Message}";
            Log.Error($"domain: {d.Realm} was NOT joined — {d.JoinedDetail}");
            Log.Warn("domain: the machine is installed and unjoined. Run Join-OS7Domain "
                     + "on it once it has booted.");
        }
    }

    private void Join(Executor x, DomainPlan d)
    {
        // A plan that reached the executor invalid is a bug in Setup, not an
        // answer from an operator: `ExecuteScreen.Start` and `--unattend` are
        // the only two callers and both validate the whole plan. It is checked
        // again here for the reason `AccountStep` re-checks its hash — "cannot"
        // is what this file's neighbours keep disproving — and it is the last
        // defence for the single-quoted PowerShell strings below.
        var problems = new List<string>();
        d.Validate(problems);
        if (problems.Count > 0)
            throw new StepException(
                "Setup cannot join this computer to a domain.",
                "Join-OS7Domain",
                string.Join("; ", problems)
                + " — this plan should have been refused before the disk was touched.");

        if (DomainProbe.MissingTool is { } missing)
            throw new StepException(
                "Setup cannot join this computer to a domain.",
                $"command -v {missing}",
                $"{missing} is not on this setup medium, so there is nothing to join with. "
                + "It is not in any OS/7 package list yet (L35).");

        try
        {
            if (!x.DryRun)
            {
                // NO TRAILING NEWLINE, and it is the same trap `LuksStep` names:
                // whatever reads this file reads it verbatim, so a byte that was
                // never part of the password is a password that is not the one
                // that was typed. The script below reads the file whole and
                // hands the cmdlet what it asks for, which is a securestring.
                File.WriteAllBytes(KeyFile, Encoding.UTF8.GetBytes(d.Password!));
                File.SetUnixFileMode(KeyFile, UnixFileMode.UserRead | UnixFileMode.UserWrite);
            }

            // OUT TO POWERSHELL, and §6.3 is the reason — the same reason
            // `PoolsAndDatasetsStep` calls `New-OS7Storage` rather than running
            // `zpool` itself. This command line IS the contract between the
            // installer and the module, so EVERY NAME IN IT IS THE CMDLET'S OWN:
            // `Join-OS7Domain` binds its parameters before `adcli` is ever
            // started, and a name this file invented rather than read out of the
            // `param` block fails every join at binding, on a machine that is
            // otherwise finished, with an error about a parameter instead of
            // about a domain.
            //
            //   -TargetRoot      where the system being joined is mounted. The
            //                    keytab and sssd.conf go under it; the process
            //                    itself runs OUT HERE, on the live system, where
            //                    DNS and the clock are the ones screen 9 tested.
            //   -Domain          the DNS domain name, lower case.
            //   -ComputerName    the account in the directory, at most 15 chars.
            //   -OrganizationalUnit  a DN, or the argument is absent.
            //   -UserName        the account authorising the join — or
            //                    -OneTimePassword instead, which says the
            //                    computer account already exists and the
            //                    password is its one-time one. One of the two is
            //                    always passed: with neither, `adcli` is given
            //                    no way to authenticate at all.
            //   -Password        a securestring, built here out of the keyfile.
            //
            // THE SECRET IS A PATH ON THIS COMMAND LINE AND NEVER A VALUE, which
            // is what makes `Executor.Exec` logging it in full safe, and what
            // keeps it out of `ps` on a machine somebody may be watching over
            // the operator's shoulder. `$secret` is built inside the pwsh
            // process, and the keyfile is removed TWICE — by the script's own
            // `finally` as soon as the join is over, and again by this method's,
            // because a pwsh that never started never runs the first one.
            string script =
                "Import-Module /usr/local/share/powershell/Modules/OS7/OS7.psd1 -Force; " +
                $"$secret = [System.IO.File]::ReadAllText('{KeyFile}') " +
                "| ConvertTo-SecureString -AsPlainText -Force; " +
                "try { Join-OS7Domain " +
                $"-TargetRoot '{_t.Root}' " +
                $"-Domain '{d.Realm}' " +
                $"-ComputerName '{d.ComputerName}' " +
                OrganizationalUnitArgument(d) +
                JoinAccountArgument(d) +
                "-Password $secret " +
                (x.DryRun ? "-WhatIf" : "-Confirm:$false") +
                " } finally { Remove-Item -LiteralPath " +
                $"'{KeyFile}' -Force -ErrorAction SilentlyContinue }}";

            // `Executor.Exec` and not a runner of this file's own: it already
            // starts the process without a shell, logs the command line, keeps
            // the last of stderr and turns a non-zero exit into the
            // `StepException` the caller above is catching. What it does not do
            // is echo the module's progress lines one at a time the way
            // `PoolsAndDatasetsStep`'s private runner does — worth having, and
            // not worth a second process runner in this file to get.
            x.Exec("pwsh", "-NoProfile", "-NonInteractive", "-Command", script);
        }
        finally
        {
            try { if (File.Exists(KeyFile)) File.Delete(KeyFile); }
            catch (Exception ex) { Log.Warn($"could not remove {KeyFile}: {ex.Message}"); }
        }

        // THE CHECK IS THE FILE ON THE TARGET, NEVER THE EXIT CODE — the same
        // rule that made `NetworkStep` read back the unit `netplan generate`
        // produced and `AccountStep` read `/etc/shadow` rather than trust
        // `useradd`. Two chroots and not one, because the two questions have
        // different answers: "did this computer join" and "can this computer
        // use the join" fail separately and mean different things.
        Prove(x, d);

        if (!x.DryRun)
        {
            // BETWEEN THE TWO PROOFS, and that is the whole of it: the join is
            // recorded once the keytab has been read back, and `ProveUsable`
            // below REPLACES this sentence when the configuration is unusable.
            // Written after both, it would overwrite the only record that the
            // machine has a computer account it cannot use.
            d.Joined = true;
            d.JoinedDetail = $"joined {d.Realm} as {d.ComputerName}";
            Log.Info($"domain: {d.JoinedDetail}");
        }

        ProveUsable(x, d);
    }

    /// <summary>`-OrganizationalUnit '<dn>' `, or nothing. Absent rather than
    /// empty: an empty DN is a real value to a directory and means something
    /// else entirely.</summary>
    private static string OrganizationalUnitArgument(DomainPlan d) =>
        string.IsNullOrWhiteSpace(d.OrganizationalUnit)
            ? ""
            : $"-OrganizationalUnit '{d.OrganizationalUnit!.Trim()}' ";

    /// <summary>
    /// `-UserName '<account>' ` or `-OneTimePassword `, and the second is the
    /// PREFERRED one rather than a fallback.
    ///
    /// No account named means the computer account was created in the directory
    /// beforehand and the password is its one-time password, which is how a
    /// machine gets joined without a domain administrator's password being typed
    /// into a text-mode installer. `DomainPlan.UsesOneTimePassword` derives the
    /// same answer for the screen, from the same field, so the two cannot
    /// disagree.
    ///
    /// NEITHER BRANCH MAY EMIT NOTHING. `Join-DirectoryRealm` passes
    /// `--one-time-password` for the first and `--login-user` for the second,
    /// and with neither switch `adcli` is asked to join with no credential at
    /// all — a join that fails against the directory rather than at the console
    /// where the answer was typed.
    /// </summary>
    private static string JoinAccountArgument(DomainPlan d)
    {
        if (d.UsesOneTimePassword)
        {
            Log.Info("domain: no join account named; the computer account must already "
                     + "exist and the password is its one-time password");
            return "-OneTimePassword ";
        }
        Log.Info($"domain: joining as {d.JoinAccount}");
        return $"-UserName '{d.JoinAccount!.Trim()}' ";
    }

    /// <summary>
    /// Did this computer join? Asked of `/etc/krb5.keytab`, inside the target.
    ///
    /// THE KEYTAB'S OWN BYTES ARE THE PRIMARY WITNESS, and that is not
    /// pedantry. `klist` comes from `krb5-user`, which is NOT installed on the
    /// shipped image — measured 2026-08-27 against
    /// `out/OS7-1.0.0.116-amd64.packages.manifest` — so a check written around
    /// `klist` would report "not joined" on every machine this installer can
    /// currently produce, which is a diagnostic reporting its own absence as a
    /// defect in the thing it was pointed at. A keytab starts `05 02` (or `05
    /// 01` for the older layout), and `od` is coreutils.
    ///
    /// `klist` is still used WHERE THERE IS ONE, because it is the independent
    /// witness: it reads the file with the library the machine will use, and it
    /// is the only thing that can say the principals belong to the realm that
    /// was asked for rather than to some realm.
    /// </summary>
    private void Prove(Executor x, DomainPlan d)
    {
        // The Kerberos realm is the upper-case of the DNS domain, by
        // construction in Active Directory — see DomainPlan.Realm.
        string realm = d.Realm!.ToUpperInvariant();

        _t.Chroot(x, "domain", $"""
            echo ">>> what the join left on this computer"

            if [ ! -s /etc/krb5.keytab ]; then
                echo "!!! /etc/krb5.keytab is missing or empty: nothing joined" >&2
                exit 1
            fi

            # `|| true` IS NOT DECORATION here either. TargetRoot.Chroot wraps
            # this in `set -euo pipefail`, and every command below whose failure
            # is a RESULT rather than an accident has to say so, or the script
            # dies before it can print the sentence that explains what happened.
            MAGIC=$(od -An -tx1 -N2 /etc/krb5.keytab | tr -d ' \n' || true)
            if [ "$MAGIC" != "0502" ] && [ "$MAGIC" != "0501" ]; then
                echo "!!! /etc/krb5.keytab starts $MAGIC; a keytab starts 0502" >&2
                exit 1
            fi
            SIZE=$(stat -c %s /etc/krb5.keytab)
            MODE=$(stat -c %a /etc/krb5.keytab)
            echo "    /etc/krb5.keytab is a keytab: $MAGIC, $SIZE bytes, mode $MODE"
            if [ "$MODE" != "600" ]; then
                echo "!!! that file is this computer's identity and is mode $MODE" >&2
                exit 1
            fi

            if command -v klist >/dev/null 2>&1; then
                klist -k /etc/krb5.keytab | sed 's/^/      /'
                N=$(klist -k /etc/krb5.keytab | grep -c '@{realm}' || true)
                if [ "$N" -lt 1 ]; then
                    echo "!!! no principal in the keytab belongs to {realm}" >&2
                    exit 1
                fi
                echo "    $N principal(s) for {realm}, read back with klist"
            else
                echo "    NOTE: krb5-user is not installed, so there is no klist and"
                echo "    NOTE: the keytab was checked by its bytes rather than read."
            fi
            """);
    }

    /// <summary>
    /// Can this computer USE the join? A separate question, asked separately,
    /// and its failure is not the join's failure.
    ///
    /// A machine with a keytab and no `sssd.conf` has a computer account in
    /// somebody's directory and no way to authenticate anybody — the join
    /// happened and is useless, which is a different sentence from "the join
    /// did not happen" and has to be reported as one. The file is
    /// `Join-OS7Domain`'s to write, for the same reason the join itself is: an
    /// operator joining a running machine needs exactly the same file.
    /// </summary>
    private void ProveUsable(Executor x, DomainPlan d)
    {
        try
        {
            _t.Chroot(x, "domain", """
                echo ">>> whether this computer can use the join"

                if [ ! -s /etc/sssd/sssd.conf ]; then
                    echo "!!! /etc/sssd/sssd.conf is missing: this computer has an" >&2
                    echo "!!! account in the directory and no way to log anybody in" >&2
                    exit 1
                fi
                SMODE=$(stat -c %a /etc/sssd/sssd.conf)
                if [ "$SMODE" != "600" ]; then
                    # Not a preference: sssd refuses to start on a config file
                    # anybody can read, and the refusal arrives at the first boot
                    # rather than here.
                    echo "!!! /etc/sssd/sssd.conf is mode $SMODE, not 600" >&2
                    exit 1
                fi
                if ! grep -q '^\[domain/' /etc/sssd/sssd.conf; then
                    echo "!!! /etc/sssd/sssd.conf names no domain" >&2
                    exit 1
                fi
                echo "    /etc/sssd/sssd.conf is mode $SMODE and names a domain"

                if ! command -v sssd >/dev/null 2>&1; then
                    echo "!!! sssd is not installed here, so nothing reads that file" >&2
                    exit 1
                fi

                # FROM THE SYMLINK, not from systemctl's opinion — the same
                # reasoning as NetworkStep's networkd check. `enable` reports
                # success on units that will not run, and what decides at boot is
                # whether the want exists on disk.
                if [ -e /etc/systemd/system/multi-user.target.wants/sssd.service ] ||
                   systemctl is-enabled sssd >/dev/null 2>&1; then
                    echo "    sssd is enabled and will start at boot"
                else
                    echo "!!! sssd is NOT enabled: no domain user can log in" >&2
                    exit 1
                fi
                """);
        }
        catch (StepException ex)
        {
            // The join stands. `Joined` stays true because the directory has a
            // computer account for this machine and saying otherwise would be a
            // lie in the direction that leaves an orphan behind; what is
            // recorded is that the machine cannot yet use it.
            d.JoinedDetail = $"joined {d.Realm}, but this computer cannot use it: {ex.Output}";
            Log.Error($"domain: {d.JoinedDetail}");
            Log.Warn("domain: the computer account exists. Finish the configuration with "
                     + "Repair-OS7Domain once the machine has booted, or remove the account.");
        }
    }
}
