#!/usr/bin/bash

#excluye los archivos ya cacheados, los borra del git
git ls-files -zci --exclude-standard | xargs -0 -r git rm --cached