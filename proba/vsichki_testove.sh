#!/bin/zsh
# Пускане на Mac:  PWSH=/път/до/pwsh zsh proba/vsichki_testove.sh
DIR=${0:A:h}
# Всички проби на Arhiv.ps1. Изход: ред "ОК"/"ГРЕШКА" за всяка проба.
S=${TMPDIR:-/tmp}/arhiv-proba; mkdir -p $S
P=${PWSH:-pwsh}
T=$S/t2
SRC="$DIR/../Arhiv.ps1"
rm -rf $T; mkdir -p $T/sk $T/pmserver/data $T/pmserver/node_modules/x $T/лични/снимки $T/other/pmserver
cp "$SRC" $T/sk/Arhiv.ps1
sed -e 's/Start-Sleep -Seconds 120/Start-Sleep -Seconds 2/' -e 's/Start-Sleep -Seconds (\$ProverkaMin \* 60)/Start-Sleep -Seconds 3/' "$SRC" > $T/sk/Fon.ps1
echo "db" > $T/pmserver/data/app.db; echo "зает" > $T/pmserver/data/zaet.db; chmod 000 $T/pmserver/data/zaet.db
echo "nm" > $T/pmserver/node_modules/x/a.js; echo "log" > $T/pmserver/run.log
head -c 2000000 /dev/urandom > $T/лични/снимки/с1.jpg; echo "бележка" > "$T/лични/Бележка №1.txt"
echo "друг" > $T/other/pmserver/b.txt
cd $T/sk
FAIL=0
ok(){ echo "ОК      $1"; }
bad(){ echo "ГРЕШКА  $1"; FAIL=1; }
cfg(){ printf '%s\r\n' "$@" > nastroiki.txt; }

# 1 непопълнен шаблон
cp "$DIR/../nastroiki.txt" nastroiki.txt
$P -NoProfile -File Arhiv.ps1 -Sega | grep -q "нито една папка" && ok "шаблон без пътища -> ясна грешка" || bad "шаблон"
# 2 CEL вътре в IZVOR
cfg "IZVOR=$T/pmserver" "CEL=$T/pmserver/arh"
$P -NoProfile -File Arhiv.ps1 -Sega | grep -q "ВЪТРЕ" && ok "CEL вътре в IZVOR -> отказ" || bad "CEL вътре"
# 3 MAKS невалиден
cfg "IZVOR=$T/pmserver" "CEL=$T/A" "MAKS_ARHIVI=пет"
$P -NoProfile -File Arhiv.ps1 -Sega | grep -q "цяло число" && ok "MAKS=пет -> ясна грешка" || bad "MAKS"
# 4 две папки + PROPUSNI + зает файл + липсваща трета
cfg "IZVOR=$T/pmserver" "IZVOR=\"$T/лични\"" "IZVOR=$T/НЯМА" "CEL=$T/A" "MAKS_ARHIVI=3" "PROPUSNI=node_modules; *.log"
OUT=$($P -NoProfile -File Arhiv.ps1 -Sega)
echo "$OUT" | sed 's/^/        | /'
echo "$OUT" | grep -q "\[pmserver\] ГОТОВ.*1 файла.*изключени по PROPUSNI 2.*ПРОПУСНАТИ 1" && ok "pmserver: архив минава, заетият файл прескочен, PROPUSNI работи" || bad "pmserver"
echo "$OUT" | grep -q "\[лични\] ГОТОВ.*2 файла" && ok "лични: архив готов" || bad "лични"
echo "$OUT" | grep -q "\[НЯМА\] НЕ Е НАПРАВЕН" && ok "липсваща папка не спира другите" || bad "липсваща"
Z=$(ls $T/A/лични/*.zip | head -1)
rm -rf $S/ux2; mkdir $S/ux2; unzip -q "$Z" -d $S/ux2
cmp $S/ux2/лични/снимки/с1.jpg $T/лични/снимки/с1.jpg && grep -q бележка "$S/ux2/лични/Бележка №1.txt" && ok "съдържанието на архива съвпада (кирилица)" || bad "съдържание"
# 5 ротация 3 + чужд файл не се пипа
echo "чужд" > $T/A/pmserver/pmserver_важно.zip
for i in 1 2 3 4; do sleep 1; $P -NoProfile -File Arhiv.ps1 -Sega > /dev/null; done
N=$(ls $T/A/pmserver | grep -c '^pmserver_2.*\.zip$')
[ "$N" = 3 ] && [ -f $T/A/pmserver/pmserver_важно.zip ] && ok "пази точно 3, чуждият файл стои" || bad "ротация ($N)"
# 6 еднакви имена на папки
cfg "IZVOR=$T/pmserver" "IZVOR=$T/other/pmserver" "CEL=$T/B"
$P -NoProfile -File Arhiv.ps1 -Sega > /dev/null
[ -d $T/B/pmserver ] && [ -d $T/B/pmserver_2 ] && ok "две папки с едно име -> pmserver и pmserver_2" || bad "еднакви имена"
# 7 фонов режим: наваксване + един процес + не повтаря
rm -rf $T/C; mkdir -p $T/C/pmserver
echo old > $T/C/pmserver/pmserver_2026-11-01_09-00-00.zip
printf 'IZVOR=%s\r\nIZVOR=%s\r\nCEL=%s\r\n' $T/pmserver "$T/лични" $T/C | iconv -f UTF-8 -t CP1251 > nastroiki.txt
: > arhiv_log.txt
$P -NoProfile -File Fon.ps1 &
A=$!
sleep 1
$P -NoProfile -File Fon.ps1 &
B=$!
sleep 14
if kill -0 $B 2>/dev/null; then bad "втори процес остана"; kill $B; else ok "втори процес не тръгва"; fi
kill $A; wait 2>/dev/null
G=$(grep -c "ГОТОВ" arhiv_log.txt)
[ "$G" = 2 ] && ok "фон: стар архив -> наваксва веднага, по 1 за папка, после не повтаря (ANSI настройки)" || { bad "фон ($G)"; cat arhiv_log.txt; }
# 8 празна папка, UTF-16, съобщението веднъж
mkdir -p $T/Празна
{ printf '\xff\xfe'; printf 'IZVOR=%s\r\nCEL=%s\r\n' $T/Празна $T/D | iconv -f UTF-8 -t UTF-16LE; } > nastroiki.txt
: > arhiv_log.txt
$P -NoProfile -File Fon.ps1 &
A=$!
sleep 12
kill $A; wait 2>/dev/null
E=$(grep -c "е празна" arhiv_log.txt)
[ "$E" = 1 ] && ok "празна папка -> без архив, съобщението само веднъж (UTF-16 настройки)" || bad "празна ($E)"
chmod 644 $T/pmserver/data/zaet.db
rm -f Fon.ps1
[ $FAIL = 0 ] && echo "ВСИЧКИ ПРОБИ МИНАХА" || echo "ИМА ПАДНАЛИ ПРОБИ"
