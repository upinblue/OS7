<#
.SYNOPSIS
	What /usr/libexec/os7-container-helper{,-destroy} run, as root, under
	pkexec. Internal.

.DESCRIPTION
	docs/CONTAINERS-PLAN.md CT5. The Containers window never runs as root; when
	the operator is not one of the accounts that hold the engine's socket, it
	signs in through polkit and sends each verb here.

	THIS FILE DECIDES NOTHING. Which verbs exist, which class each is, and what
	each one does are Invoke-OS7ContainerVerb's table, in the OS7 module — the
	same table the window reaches directly when it does not need this. What is
	here is the trust boundary, and only that:

	  * the CHANNEL comes from the wrapper pkexec started, never from the
	    caller: `operate` runs Read and Operate verbs, `destroy` runs Destroy
	    verbs, `install` runs the one Install verb, and Invoke-OS7ContainerVerb
	    refuses the rest by name;
	  * every argument is refused if it carries a control character — a
	    container name never does, and a line break is how an argument would
	    turn into something else further down. `\z`, not `$`: in .NET `$`
	    matches before a trailing newline (BUILD-NOTES #151);
	  * the answer is JSON on stdout and a refusal is ONE sentence on stderr
	    with a non-zero exit, which is what OS7.Shell reads.

	A verb that takes a description reads it on standard input, which pkexec
	passes through. It is never a command-line argument, because a command line
	is readable by every account on the machine and a container's environment
	holds passwords.
#>
[CmdletBinding()]
param(
	[Parameter(Mandatory)][ValidateSet('operate', 'destroy', 'install')][string]$Channel,
	[Parameter(Mandatory)][ValidatePattern('^[a-z][a-z-]{0,31}\z')][string]$Verb,
	[Parameter(ValueFromRemainingArguments)][string[]]$Argument = @()
)

$ErrorActionPreference = 'Stop'
$PSStyle.OutputRendering = 'PlainText'
$ErrorView = 'NormalView'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

foreach ($a in $Argument) {
	if ($a -notmatch '^[^\x00-\x1f\x7f]{0,256}\z') {
		[Console]::Error.WriteLine("os7-container-helper: an argument to '$Verb' carries a control character or is too long, so nothing was run.")
		exit 2
	}
}

$classes = switch ($Channel) {
	'destroy' { @('Destroy') }
	'install' { @('Install') }
	default { @('Read', 'Operate') }
}

try {
	Import-Module OS7 -ErrorAction Stop
	Invoke-OS7ContainerVerb -Verb $Verb -Argument $Argument -Class $classes
}
catch {
	[Console]::Error.WriteLine($_.Exception.Message)
	exit 1
}
