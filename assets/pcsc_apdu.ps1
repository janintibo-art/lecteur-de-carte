param([ValidateSet('select-mf','read-16')][string]$Action = 'select-mf')
$ErrorActionPreference = 'Stop'
$source = @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class CardTransport {
 [DllImport("winscard.dll", CharSet=CharSet.Unicode)] public static extern int SCardEstablishContext(uint scope, IntPtr p1, IntPtr p2, out IntPtr ctx);
 [DllImport("winscard.dll", CharSet=CharSet.Unicode)] public static extern int SCardListReaders(IntPtr ctx, string groups, StringBuilder readers, ref uint count);
 [DllImport("winscard.dll", CharSet=CharSet.Unicode)] public static extern int SCardConnect(IntPtr ctx, string reader, uint share, uint preferred, out IntPtr card, out uint protocol);
 [DllImport("winscard.dll")] public static extern int SCardTransmit(IntPtr card, IntPtr sendPci, byte[] send, uint sendLen, IntPtr recvPci, [Out] byte[] recv, ref uint recvLen);
 [DllImport("winscard.dll")] public static extern int SCardDisconnect(IntPtr card, uint disposition);
 [DllImport("winscard.dll")] public static extern int SCardReleaseContext(IntPtr ctx);
}
'@
Add-Type -TypeDefinition $source
$cmd = if ($Action -eq 'select-mf') { [byte[]](0,164,0,0,2,63,0) } else { [byte[]](0,176,0,0,16) }
$context = [IntPtr]::Zero
$rc = [CardTransport]::SCardEstablishContext(2,[IntPtr]::Zero,[IntPtr]::Zero,[ref]$context)
if ($rc -ne 0) { throw ('PC/SC indisponible : 0x{0:X8}' -f [uint32]$rc) }
try {
 [uint32]$size = 0
 $rc = [CardTransport]::SCardListReaders($context,$null,$null,[ref]$size)
 if ($rc -ne 0 -or $size -eq 0) { throw 'Aucun lecteur PC/SC disponible.' }
 $buffer = New-Object System.Text.StringBuilder ([int]$size)
 $rc = [CardTransport]::SCardListReaders($context,$null,$buffer,[ref]$size)
 if ($rc -ne 0) { throw 'Impossible de lire la liste des lecteurs.' }
 $names = @($buffer.ToString().TrimEnd([char]0).Split([char]0) | Where-Object { $_ })
 $chosen = $null
 foreach ($name in $names) {
   $card = [IntPtr]::Zero
   [uint32]$protocol = 0
   $rc = [CardTransport]::SCardConnect($context,$name,2,3,[ref]$card,[ref]$protocol)
   if ($rc -eq 0) { $chosen = $name; break }
 }
 if ($null -eq $chosen) { throw 'Aucune carte disponible dans les lecteurs.' }
 try {
   if ($protocol -ne 1 -and $protocol -ne 2) { throw 'Protocole T=0/T=1 non disponible.' }
   $pci = [Runtime.InteropServices.Marshal]::AllocHGlobal(8)
   try {
     [Runtime.InteropServices.Marshal]::WriteInt32($pci,0,[int]$protocol)
     [Runtime.InteropServices.Marshal]::WriteInt32($pci,4,8)
     [byte[]]$response = New-Object byte[] 4096
     [uint32]$responseLength = [uint32]$response.Length
     $rc = [CardTransport]::SCardTransmit($card,$pci,$cmd,[uint32]$cmd.Length,[IntPtr]::Zero,$response,[ref]$responseLength)
     if ($rc -ne 0) { throw ('Echec APDU PC/SC : 0x{0:X8}' -f [uint32]$rc) }
     if ($responseLength -lt 2) { throw 'Réponse APDU trop courte.' }
     $hex = [BitConverter]::ToString($response,0,[int]$responseLength).Replace('-',' ')
     [pscustomobject]@{lecteur=$chosen; protocole=$(if ($protocol -eq 1) {'T=0'} else {'T=1'}); action=$Action; commande=([BitConverter]::ToString($cmd).Replace('-',' ')); reponse=$hex; sw=('{0:X2}{1:X2}' -f $response[$responseLength-2],$response[$responseLength-1])} | ConvertTo-Json -Compress
   } finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($pci) }
 } finally { [void][CardTransport]::SCardDisconnect($card,0) }
} finally { [void][CardTransport]::SCardReleaseContext($context) }
