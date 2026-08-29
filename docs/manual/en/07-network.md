# 7 Network

Underneath sits **netplan**: a description file says what should hold, and a
renderer — `systemd-networkd` on a server, `NetworkManager` on a desktop —
carries it out. The OS/7 cmdlets write that description, apply it, and **then
ask the kernel** whether anything came of it.

## 7.1 What is there

```powershell
Get-OS7NetworkAdapter
```

![The machine's adapters, with what is actually on them.](images/60-adapters.png)

The output names the adapter, its kind, the MAC address, the link state and the
addresses the kernel currently holds. `-Name` asks about one adapter;
`-IncludeLoopback` includes `lo`.

## 7.2 Configured and effective

```powershell
Get-OS7NetworkConfiguration | Format-List
```

![Two separate answers: what netplan says, and what is actually the case on the machine.](images/61-network-config.png)

This is where the pattern from chapter 1.5 earns the most. The command returns
**both, separately**:

* the **configured** side: the merged netplan files, with the files each
  statement came from named, and which renderer is responsible;
* the **effective** side: the addresses, routes and name servers that actually
  hold right now.

The machine where the two disagree is the interesting one. A common case: a
netplan file describes an adapter this machine does not have — because a disk
image came from another device, say. netplan accepts that in silence and
configures nothing. OS/7 reports it.

## 7.3 Configuring an adapter

To DHCP:

```powershell
Set-OS7NetworkAdapter -Name enp0s31f6 -Dhcp
```

To a static address:

```powershell
Set-OS7NetworkAdapter -Name enp0s31f6 `
    -Address 192.0.2.25/24 `
    -Gateway 192.0.2.1 `
    -Nameserver 192.0.2.10, 192.0.2.11 `
    -SearchDomain contoso.local
```

What the command does, and the order is the point:

1. The existing configuration is kept.
2. The new description is written and applied.
3. The command **waits** until the kernel reports an address on the adapter
   (`-TimeoutSeconds` says how long), and on a static configuration for the
   gateway as well.
4. If nothing comes up, **the old configuration is put back and applied
   again**.

That defuses the classic remote-administration accident — a wrong static
address does not cut the connection permanently, because the machine goes back
on its own.

One thing must never happen quietly: if the rollback also fails, the command
says so explicitly. A result carrying `RollbackFailed` is a machine that needs
hands at the console — not one to be ignored.

`-Force` skips the confirmation for an adapter the current session is running
over.

## 7.4 Testing reachability

```powershell
Test-OS7Network | Format-List Ok,HasLink,DnsWorks
```

![Test-OS7Network checks not only whether the machine is "online" but whether it reaches the services OS/7 exists to reach.](images/62-test-network.png)

The per-endpoint results hang off the result as a property:

```powershell
(Test-OS7Network).Endpoints | Format-Table -AutoSize
```

![Each endpoint that was tested, with its result.](images/63-endpoints.png)

The command walks the chain — link, gateway, name resolution, endpoints — and
says where it breaks. That is the difference between "the network is down" and
"DNS answers but the sign-in endpoints are blocked".

Which endpoints exist:

```powershell
Get-OS7Endpoint | Format-Table Name,Host,Port
```

![The endpoints OS/7 knows about and can test.](images/64-endpoint-list.png)

The list is a data file beside the module rather than code — sovereign clouds
have other host names. `-Cloud` tests against another cloud, `-Endpoint` picks
individual ones:

```powershell
Test-OS7Network -Endpoint Entra, Intune
Get-OS7Endpoint -Cloud UsGov
```

## 7.5 Remote administration with no network

For completeness: if a machine is no longer reachable over the network, the
entire command surface works over a serial console. That is not luck but a
requirement — every cmdlet in this manual has to be usable on a serial line.
