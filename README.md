# Bootstrap

Small public bootstrap scripts, meant to be loaded with `curl`.

## repo-run.sh

Generic loader: fetch a (private) git repo and run a script from it — SSH-key or
token auth, any git host. Run it locally, or bootstrap it via curl:

```bash
bash <(curl -fsSL 'https://raw.githubusercontent.com/JJaeger79/Bootstrap/main/repo-run.sh') \
  --repo '<owner/repo>' --script '<path/in/repo>'
```

Re-running updates (the cache is pulled to the latest ref, then the script runs).
See `repo-run.sh --help` for all options.
