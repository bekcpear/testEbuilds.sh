## testEbuilds.sh

This is a script to test ebuilds on Gentoo Linux.

deps:

- BtrFS
- bubblewrap

e.g.

setup the first few lines in the shell, and run:

```bash
# parallel mode
./testEbuilds.sh -d /path/to/_test_conf_root -r /path/to/extra/repo fcitx5-rime fcitx5-configtool fcitx5-gtk

# interactive mode
./testEbuilds.sh -d /path/to/_test_conf_root -r /path/to/extra/repo -i
```

