#!/usr/bin/env bash
eval "$(/opt/homebrew/bin/brew shellenv)"

echo $(which fish) | sudo tee -a /etc/shells

chsh -s $(which fish)
