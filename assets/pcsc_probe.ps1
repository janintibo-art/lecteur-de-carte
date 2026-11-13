$ErrorActionPreference = 'Stop'
$src = @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class Pcsc {
  [DllImport("winscard.dll", CharSet=CharSet.Unicode)]
  public static extern int SCardEstablishContext(uint scope, IntPtr reserved1, IntPtr reserved2, out IntPtr context);
  [DllImport("winscard.dll", CharSet=CharSet.Unicode)]
  public static extern int SCardListReaders(IntPtr context, string groups, StringBuilder readers, ref uint length);
  [DllImport("winscard.dll", CharSet=CharSet.Unicode)]
  public static extern int SCardConnect(IntPtr context, string reader, uint shareMode, uint preferredProtocols, out IntPtr card, out uint activeProtocol);
  [DllImport("winscard.dll", CharSet=CharSet.Unicode)]
  public static extern int SCardStatus(IntPtr card, StringBuilder readerName, ref uint readerLen, out uint state, out uint protocol, [Out] byte[] atr, ref uint atrLen);
  [DllImport("winscard.dll")]
  public static extern int SCardDisconnect(IntPtr card, uint disposition);
  [DllImport("winscard.dll")]
  public static extern int SCardReleaseContext(IntPtr context);
}
'@
Add-Type -TypeDefinition $src
$context = [IntPtr]::Zero
$rc = [Pcsc]::SCardEstablishContext(2, [IntPtr]::Zero, [IntPtr]::Zero, [ref]$context)
if ($rc -ne 0) { throw ('Service PC/SC indisponible : 0x{0:X8}' -f [uint32]$rc) }
try {
  [uint32]$length = 0
  $rc = [Pcsc]::SCardListReaders($context, $null, $null, [ref]$length)
  if (('0x{0:X8}' -f [uint32]$rc) -eq '0x8010002E') { '[]'; exit 0 } # SCARD_E_NO_READERS_AVAILABLE
  if ($rc -ne 0) { throw ('Liste lecteurs : 0x{0:X8}' -f [uint32]$rc) }
  $buffer = New-Object System.Text.StringBuilder ([int]$length)
  $rc = [Pcsc]::SCardListReaders($context, $null, $buffer, [ref]$length)
  if ($rc -ne 0) { throw ('Lecture liste : 0x{0:X8}' -f [uint32]$rc) }
  $names = @($buffer.ToString().TrimEnd([char]0).Split([char]0) | Where-Object { $_ })
  $results = @()
  foreach ($name in $names) {
    $card = [IntPtr]::Zero
    [uint32]$proto = 0
    $rc = [Pcsc]::SCardConnect($context, $name, 2, 3, [ref]$card, [ref]$proto)
    if ($rc -ne 0) {
      $results += [pscustomobject]@{ lecteur=$name; carte='absente ou indisponible'; code=('0x{0:X8}' -f [uint32]$rc) }
      continue
    }
    try {
      $readerName = New-Object System.Text.StringBuilder 512
      [uint32]$readerLength = 512
      [uint32]$state = 0
      [uint32]$statusProto = 0
      [byte[]]$atr = New-Object byte[] 64
      [uint32]$atrLength = 64
      $status = [Pcsc]::SCardStatus($card, $readerName, [ref]$readerLength, [ref]$state, [ref]$statusProto, $atr, [ref]$atrLength)
      if ($status -eq 0) {
        $hex = if ($atrLength -gt 0) { [BitConverter]::ToString($atr, 0, [int]$atrLength).Replace('-', ' ') } else { '' }
        $results += [pscustomobject]@{ lecteur=$name; carte='presente'; protocole=$(if ($statusProto -eq 1) {'T=0'} elseif ($statusProto -eq 2) {'T=1'} else {'Inconnu'}); ATR=$hex }
      } else {
        $results += [pscustomobject]@{ lecteur=$name; carte='connectee'; erreurStatus=('0x{0:X8}' -f [uint32]$status) }
      }
    } finally { [void][Pcsc]::SCardDisconnect($card, 0) }
  }
  ConvertTo-Json -InputObject @($results) -Depth 4
} finally { [void][Pcsc]::SCardReleaseContext($context) }
