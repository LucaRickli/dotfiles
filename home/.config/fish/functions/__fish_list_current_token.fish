function __fish_list_current_token --description 'List contents of token under the cursor if it is a directory, otherwise list the contents of the current directory'
    set -l val (commandline -t | string collect)
    set -l cmd
    if test -d "$val"
        set cmd ls -lAp $val
    else
        set -l dir (dirname -- $val)
        if test $dir != . -a -d $dir
            set cmd ls -lAp $dir
        else
            set cmd ls -lAp
        end
    end

    __fish_echo $cmd
end
