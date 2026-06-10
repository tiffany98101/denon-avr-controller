# fish completion for denon-avr-controller

set -l denon_commands \
    status info data rawstatus raw signal-debug snapshot diff dashboard dashboard-alt dashboard-ultra \
    on off vol up down mute unmute toggle \
    source sources rename-source source-names clear-source-name \
    zone2 heos \
    movie game music night mode dyn-eq dyn-vol cinema-eq multeq \
    bass treble \
    play pause stop next prev previous track now \
    sleep qs preset watch-event \
    discover setip doctor config profile completion \
    version help \
    xbox xfinity bluray tv phono

complete -c denon -f
complete -c denon -n "__fish_use_subcommand" -a "$denon_commands"

complete -c denon -n "__fish_seen_subcommand_from completion; and not __fish_seen_subcommand_from bash zsh fish install" -a "bash" -d "Generate bash completion script"
complete -c denon -n "__fish_seen_subcommand_from completion; and not __fish_seen_subcommand_from bash zsh fish install" -a "zsh" -d "Generate zsh completion script"
complete -c denon -n "__fish_seen_subcommand_from completion; and not __fish_seen_subcommand_from bash zsh fish install" -a "fish" -d "Generate fish completion script"
complete -c denon -n "__fish_seen_subcommand_from completion; and not __fish_seen_subcommand_from bash zsh fish install" -a "install" -d "Install shell completion"

complete -c denon -n "__fish_seen_subcommand_from completion; and __fish_seen_subcommand_from install" -l shell -xa "bash zsh fish" -d "Shell type"
complete -c denon -n "__fish_seen_subcommand_from completion; and __fish_seen_subcommand_from install" -l force -d "Overwrite an existing completion file"

complete -c denon -n "__fish_seen_subcommand_from source" -a "tv heos bluray game phono xbox xfinity"
complete -c denon -n "__fish_seen_subcommand_from raw" -a "get set dump types"
complete -c denon -n "__fish_seen_subcommand_from mode" -a "stereo direct pure pure-direct movie music game auto"
complete -c denon -n "__fish_seen_subcommand_from dyn-eq cinema-eq" -a "on off"
complete -c denon -n "__fish_seen_subcommand_from dyn-vol" -a "off light medium heavy"
complete -c denon -n "__fish_seen_subcommand_from multeq" -a "reference audyssey bypass-lr flat manual off"
complete -c denon -n "__fish_seen_subcommand_from sleep" -a "off 30 60 90 120"
