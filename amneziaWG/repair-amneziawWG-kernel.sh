cd "$(mktemp -d)"
KEY=RWQXfpABHIpZPttqrwYrQNHRTk/iLIz4cVh9KkRwAElHP+CoW/NPEysN
f=install_amneziawg_en.sh
tag=
wget -q -O "$f" "https://github.com/bivlked/amneziawg-installer/releases/latest/download/$f" \
  && wget -q -O "$f.minisig" "https://github.com/bivlked/amneziawg-installer/releases/latest/download/$f.minisig" \
  && out=$(minisign -V -P "$KEY" -m "$f" -x "$f.minisig") \
  && tag=$(printf '%s\n' "$out" | sed -n "s/^Trusted comment: amneziawg-installer \(v[0-9.]*\) $f\$/\1/p")
if [ -z "$tag" ]; then
  echo "NOT VERIFIED: $f, not running"
elif [ "$(printf '%s\n' v5.37.1 "$tag" | sort -V | head -1)" != v5.37.1 ]; then
  echo "Release $tag is older than v5.37.1"
else
  echo "Verified release $tag"; sudo bash "$f" --repair-module
fi
