printf "\e[0;30m0;30m Black \e[1;30mbold Black \e[0;90mhigh intensity Black\n"
printf "\e[0;31m0;31m Red \e[1;31mbold Red \e[0;91mhigh intensity Red\n"
printf "\e[0;32m0;32m Green \e[1;32mbold Green \e[0;92mhigh intensity Green\n"
printf "\e[0;33m0;33m Yellow \e[1;33mbold Yellow \e[0;93mhigh intensity Yellow\n"
printf "\e[0;34m0;34m Blue \e[1;34mbold Blue \e[0;94mhigh intensity Blue\n"
printf "\e[0;35m0;35m Purple \e[1;35mbold Purple \e[0;95mhigh intensity Purple\n"
printf "\e[0;36m0;36m Cyan \e[1;36mbold Cyan \e[0;96mhigh intensity Cyan\n"
printf "\e[0;37m0;37m White \e[1;37mbold White \e[0;97mhigh intensity White\n"

printf "=============================================\n"
printf "Zig compatible strings to do your coloring !!\n"

printf "=============================================\n"
printf "8bit colored Background with Default text\n"
for i in {16..255}; do
    # Print the colored text with padding for alignment
    printf "\e[48;5;${i}m  %cx1b[48;5;%03dm  \e[0m  " '\\' $i
    
    # Print a newline every 6th iteration
    if (( (i - 15) % 6 == 0 )); then
        printf "\n"
    fi
done
# Ensure the final line ends cleanly
printf "\n\n"

printf "=============================================\n"
printf "8bit colored Background with Default Bold text\n"
for i in {16..255}; do
    # Print the colored text with padding for alignment
    printf "\e[48;5;${i};1m  %cx1b[48;5;%03d;1m  \e[0m  " '\\' $i
    
    # Print a newline every 6th iteration
    if (( (i - 15) % 6 == 0 )); then
        printf "\n"
    fi
done
# Ensure the final line ends cleanly
printf "\n\n"

printf "=============================================\n"
printf "8bit colored Background with Black text\n"
for i in {16..255}; do
    # Print the colored text with padding for alignment
    printf "\e[48;5;${i};1;30m  %cx1b[48;5;%03d;1;30m  \e[0m  " '\\' $i
    
    # Print a newline every 6th iteration
    if (( (i - 15) % 6 == 0 )); then
        printf "\n"
    fi
done
# Ensure the final line ends cleanly
printf "\n\n"
printf "=============================================\n"
printf "8bit colors on Black Background\n"
for i in {16..255}; do
    # Print the colored text with padding for alignment
    printf "\e[38;5;${i}m  %cx1b[38;5;%03dm  \e[0m  " '\\' $i
    
    # Print a newline every 6th iteration
    if (( (i - 15) % 6 == 0 )); then
        printf "\n"
    fi
done
# Ensure the final line ends cleanly
printf "\n\n"

printf "=============================================\n"
printf "8bit Bold colors on Black Background\n"
for i in {16..255}; do
    # Print the colored text with padding for alignment
    printf "\e[38;5;${i};1m  %cx1b[38;5;%03d;1m  \e[0m  " '\\' $i
    
    # Print a newline every 6th iteration
    if (( (i - 15) % 6 == 0 )); then
        printf "\n"
    fi
done
# Ensure the final line ends cleanly
printf "\n"
