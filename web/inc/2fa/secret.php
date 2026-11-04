<?php
require_once __DIR__ . "/provider.php";

$tfa = hestia_2fa_new();

$secret = $tfa->createSecret(160); // Though the default is an 80 bits secret (for backwards compatibility reasons) we recommend creating 160+ bits secrets (see RFC 4226 - Algorithm Requirements)

// Account name shown below the issuer in the authenticator app: "<product name>:<user>"
$account = isset($argv[1]) && $argv[1] !== "" ? $argv[1] : gethostname();
$label = hestia_2fa_issuer() . ":" . $account;
$qrcode = $tfa->getQRCodeImageAsDataUri($label, $secret);

echo $secret . "-" . $qrcode;
