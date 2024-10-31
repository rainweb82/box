url="https://www.konami.cc/bbs/1"
cookie="WAjr_2132_auth=8f67EeQOWychoFxzx5BNMhCOpbT5URIB%2BnZgpEFuJqGF58LmusyMFr%2BcReEU72gJw64H3dlvxTeT%2F8nPq%2F0cut7AWcjE;WAjr_2132_saltkey=hnR9FgQR;"

strA="`curl --retry 3 --retry-max-time 30 -L -s "$url" --cookie "$cookie"`"
printf $strA
