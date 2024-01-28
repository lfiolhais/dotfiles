# Status Chars
set __fish_git_prompt_showuntrackedfiles 'yes'
set __fish_git_prompt_showdirtystate 'yes'
set __fish_git_prompt_showstashstate 'yes'
set __fish_git_prompt_showupstream 'none'
set -g fish_prompt_pwd_dir_length 3

# Print current user
function __simple_ass_prompt_get_user -d "Print the user"
  if test $USER = 'root'
    set_color red
  else
    set_color d75f00
  end
  printf '%s' (whoami)
end

# Get Machines Hostname
function __simple_ass_prompt_get_host -d "Get Hostname"
  if test $SSH_TTY
    tput bold
    set_color red
  else
    set_color af8700
  end
  printf '%s' (hostname|cut -d . -f 1)
end

# Get Project Working Directory
function __simple_ass_prompt_pwd -d "Get PWD"
  set_color $fish_color_cwd
  printf '%s' (prompt_pwd)
end

# Simple-ass-prompt
function fish_prompt
  set -l code $status

  # Logged in user
  __simple_ass_prompt_get_user
  set_color normal
  printf '@'

  # Machine logged in to
  __simple_ass_prompt_get_host
  set_color normal
  printf ' '

  # Path
  __simple_ass_prompt_pwd
  set_color normal

  # Git
  set_color purple
  printf '%s ' (__fish_git_prompt)

  # Line 2
  set_color normal
  echo

  printf "[%s] " (set_color cyan)(date "+%H:%M")(set_color normal)
  if test -e "Cargo.toml"
    printf "(rust:%s) " (set_color red)(rustup show | tail -n 3 | head -n 1 |  cut -d '-' -f 1)(set_color normal)
  end

  if test $VIRTUAL_ENV
    printf "(python:%s) " (set_color blue)(basename $VIRTUAL_ENV)(set_color normal)
  end

  if test $code -eq 127
    set_color red
  end

  printf '↪ '
  set_color normal
end
