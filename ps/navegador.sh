#!/usr/bin/env bash
# Google Chrome per als scripts de PowerShell (Loteries i Parlament) a GitHub.
# Als servidors de GitHub, Chrome només arrenca sense «sandbox».
exec google-chrome --no-sandbox "$@"
