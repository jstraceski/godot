#!/bin/sh
# Run the custom Godot editor with Vulkan + all runtime libs, from any shell.
# Usage:  ./run-godot.sh [extra godot args...]
#   e.g.  ./run-godot.sh --editor
#         ./run-godot.sh --path poc-boids

set -e

NVIDIA_ICD="/nix/store/rsha0mmmyzsrbryja5ck9w0cdcsj1lap-nvidia-x11-595.71.05/share/vulkan/icd.d/nvidia_icd.json"

# Collect the runtime lib dirs. Prefer the dev shell's LD_LIBRARY_PATH if present;
# otherwise fall back to the known Nix store paths.
LIBS=""
if [ -n "$LD_LIBRARY_PATH" ]; then
  LIBS="$LD_LIBRARY_PATH"
fi
# Always make sure these are present (idempotent).
for d in \
  /nix/store/ackf72likmlm6wyfzqqzmrpyjn73vlsa-vulkan-loader-1.4.341.0/lib \
  /nix/store/4wkicwb2jx5h63d79g5qyp9kn4vx27yb-libx11-1.8.13/lib \
  /nix/store/qccs7f6nfqrjadfw8pag3amq5m8h34zi-libxcursor-1.2.3/lib \
  /nix/store/jkswprq04f9sm9qs2nqr287zywv8k9wf-libxext-1.3.7/lib \
  /nix/store/ncvfcirz3d4g2maj5dvzwjwrimwvnhl6-libxi-1.8.3/lib \
  /nix/store/v1zv9f9jlq2qk2jz11xls9rcqcbix51g-libxrender-0.9.12/lib \
  /nix/store/aks94skdqa6mjhwz09w2xfxs9h4j5csa-libxrandr-1.5.5/lib \
  /nix/store/yp9zski21gb257ca681qafrkm59gxv7p-libxinerama-1.1.6/lib \
  /nix/store/y5pc8yqf289q3h9higvj7y5sm4rjxgll-libxfixes-6.0.2/lib \
  /nix/store/0k2ik46qfa76v47m06r5ic9q07grivrd-libxscrnsaver-1.2.5/lib \
  /nix/store/fwmj5fpn3cpgxdivllgqg78bl810qbhb-libxpresent-1.0.2/lib \
  /nix/store/wrdsxzg2217iyvx68lz83qiy6rib7si8-libxcomposite-0.4.7/lib \
  /nix/store/idlvdrgar9qir28kjib3bvqva4c3wmf4-libxdamage-1.1.7/lib \
  /nix/store/p8wsh7r6r0bq2pk41fnh914ap9gzk1xv-libxkbcommon-1.13.1/lib \
  /nix/store/gbqpck20fdj8h2idhp2dshxhjk9malym-fontconfig-2.17.1-lib/lib \
  /nix/store/ir3ha3ghl8wvbsd4wiv5hdp7vm70zn3y-wayland-1.25.0/lib \
  /nix/store/mwlz1nal5bznpy8mlp02ry79h3083k1b-libglvnd-1.7.0/lib \
  /nix/store/ilz7zyc5wphy64ln04j12f1f206yqn4v-alsa-lib-1.2.15.3/lib \
  /nix/store/0g5ybks6m1n6yg9v0m1gydfcafc001zl-libpulseaudio-17.0/lib
do
  case ":$LIBS:" in
    *":$d:"*) ;;               # already present
    *) LIBS="$LIBS:$d" ;;
  esac
done

export LD_LIBRARY_PATH="$LIBS"
export VK_DRIVER_FILES="$NVIDIA_ICD"

exec ./bin/godot.linuxbsd.editor.dev.x86_64 "$@"
