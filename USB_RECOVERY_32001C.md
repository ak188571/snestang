# Tang Console 138K: SNESのUSB Host回復

基板表示「32001C」のSNES用SNESTang。P1/P2にUSB Host自動回復を適用する。最初のHID report後、`START`待ちが100 ms続くか`conerr`が立ったとき、Host全体を約5 ms resetする。新しいreportが届くまで自動resetを繰り返さない。S1（USER_BUTTON0、AA13）を押している間は両Hostを手動resetし、PMODの8個のLEDを全点灯する。

ゲーム中のPMOD LED0〜7は順に、P1の新button（約0.5秒）、P1 `connected`、P1の直近report（約0.5秒）、P1 `START`待ちによる自動reset履歴、P1 `conerr`による自動reset履歴、現在のP1 `conerr`、Bitstream識別用の常時点灯、約1秒周期の点滅。P2の内部履歴は表示しない。

VID:PID `0079:0006`でSNESゲーム中のP1/P2をそれぞれ約25回挿抜し、操作不能にはならなかった。P1でLED3・4の両方に自動reset履歴が残り、S1を押している間の全LED点灯と、その後の履歴消去を確認した。P2の自動reset履歴はLEDから直接確認していない。抜去直後に一時的な誤入力があったが、再接続後は通常の操作に戻ったため、今回は修正しない。

Gowin V1.9.12.03、`GW5AST-LV138PG484AC1/I0` version B、`gw_sh build.tcl console138k ds2`。設計全体のLogic 18,305/138,240、Register 8,545/139,095。報告されたsetup/hold違反は0/0だがclock間の警告が残る。採択した`cores/console138k/snestang.bin`は4,857,344 byte、SHA-256 `0803CE89D09C5AAADABF06426690DFDA1E3EBE52096D4F9AA3F0D57DADAE3D98`。元版と実機試験の詳細は作業領域の総合報告に記録した。ゲームROMとBL616 Flashは変更しない。
