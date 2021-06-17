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

# maintenance mode
./testEbuilds.sh -d /path/to/_test_conf_root -r /path/to/extra/repo -m
```

### Parallel mode

https://user-images.githubusercontent.com/6622239/122460368-9f7a0800-cfe4-11eb-96a3-5f189d32f5ec.mp4

### Interactive mode

https://user-images.githubusercontent.com/6622239/122460574-dcde9580-cfe4-11eb-815f-3a2e87586102.mp4

### Maintenance mode

https://user-images.githubusercontent.com/6622239/122460610-e9fb8480-cfe4-11eb-8eab-6612e7409958.mp4

