let s:binary_dir = expand('<sfile>:p:h:h') . '/binaries'
let s:is_win = has('win32') || has('win64')
let s:tabnine_run = v:false

function! s:get_tabnine_path(binary_dir) abort
    let l:versions = glob(fnameescape(a:binary_dir) . '/*', 1, 1)
    let l:versions = reverse(sort(l:versions))
    for l:version in l:versions
        let l:triple = s:parse_architecture('') . '-' . s:get_os()
        let l:path = join([l:version, l:triple, s:executable_name('TabNine')], '/')
        if filereadable(l:path)
            return l:path
        endif
    endfor
endfunction

function! s:get_os() abort
    if has('macunix')
        return 'apple-darwin'
    elseif has('unix')
        return 'unknown-linux-musl'
    elseif s:is_win
        return 'pc-windows-gnu'
    endif
endfunction

function! s:parse_architecture(arch) abort
    if s:is_win
        return 'x86_64'
    endif

    if has('macunix')
        return s:parse_macos_architecture()
    end

    let l:system = system('file -L "' . exepath(v:progpath) . '"')
    if  l:system =~ 'x86-64' || l:system =~ 'x86_64'
        return 'x86_64'
    endif
    return a:arch
endfunction

function! s:parse_macos_architecture() abort
    let l:system = system('uname -m')
    if  l:system =~ 'x86-64' || l:system =~ 'x86_64'
        return 'x86_64'
    elseif l:system =~ 'arm64'  " m1 mac
        return 'aarch64'
    endif
endfunction

function! s:executable_name(name) abort
    if s:is_win
        return a:name . '.exe'
    endif
    return a:name
endfunction

function! s:isJobAlive() abort
    return s:tabnine_run
endfunction

function! s:getTabNineJob() abort
    if !s:isJobAlive()
        let l:tabnine_path = s:get_tabnine_path(s:binary_dir)
        let l:jobArgs = [
                    \   l:tabnine_path,
                    \   '--log-file-path',
                    \   s:binary_dir . '/tabnine.log',
                    \ ]
        if has('nvim')
            let s:job = jobstart(l:jobArgs, {
                        \ 'on_stdout': function('s:handleStdout')
                        \ })
        else
            let s:job = job_start(l:jobArgs, {
                        \ 'out_cb': function('s:outCallBack')
                        \ })
        endif
        let s:tabnine_run = v:true
    endif
    return s:job
endfunction

function! s:getBytes(fromByte, toByte) abort
    let l:firstLine = byte2line(a:fromByte)
    let l:startByteInLine = a:fromByte - line2byte(l:firstLine)
    let l:lastLine = byte2line(a:toByte)
    let l:endByteInLine = a:toByte - line2byte(l:lastLine)

    let l:result = getline(l:firstLine, l:lastLine)

    if l:endByteInLine <= 0
        let l:result[-1] = ''
    else
        let l:result[-1] = l:result[-1][:l:endByteInLine - 1]
    endif
    if 0 < l:startByteInLine
        let l:result[0] = l:result[0][l:startByteInLine:]
    endif

    return join(l:result, "\n")
endfunction

function! s:getParamsForCompletion(maxBytes)
    let l:curByte = line2byte('.') + col('.') - 1
    let l:lastByte = line2byte('$') + len(getline('$'))
    if l:lastByte < a:maxBytes
        return {
                    \ 'before': s:getBytes(1, l:curByte),
                    \ 'region_includes_beginning': v:true,
                    \ 'after': s:getBytes(l:curByte, l:lastByte),
                    \ 'region_includes_end': v:true}
    endif

    let l:result = {
                \ 'region_includes_beginning': v:false,
                \ 'region_includes_end': v:false}

    if l:curByte <= a:maxBytes / 2 + 1
        " Can take all the bytes before
        let l:result.region_includes_beginning = v:true
        let l:result.before = s:getBytes(1, l:curByte)
        let l:result.after = s:getBytes(l:curByte, l:curByte + a:maxBytes - len(l:result.before))
    elseif l:lastByte <= l:curByte + a:maxBytes / 2
        " Can take all the bytes after
        let l:result.region_includes_end = v:true
        let l:result.after = s:getBytes(l:curByte, l:lastByte)
        let l:result.before = s:getBytes(l:curByte - a:maxBytes + len(l:result.after), l:curByte)
    else
        " Should split them
        let l:result.before = s:getBytes(l:curByte - a:maxBytes / 2, l:curByte)
        let l:result.after = s:getBytes(l:curByte, l:curByte + a:maxBytes / 2)
    endif
    return l:result
endfunction

function! s:genComplete(msg) abort
    let l:response = json_decode(a:msg)
    let l:words = []
    for l:result in l:response['results']
        let l:word = {}

        let l:new_prefix = get(l:result, 'new_prefix')
        if l:new_prefix == ''
            continue
        endif
        let l:word['word'] = l:new_prefix

        if get(l:result, 'old_suffix', '') != '' || get(l:result, 'new_suffix', '') != ''
            let l:user_data = {
                        \   'old_suffix': get(l:result, 'old_suffix', ''),
                        \   'new_suffix': get(l:result, 'new_suffix', ''),
                        \ }
            let l:word['user_data'] = json_encode(l:user_data)
        endif

        let l:word['menu'] = '[tabnine]'
        if get(l:result, 'detail')
            let l:word['menu'] .= ' ' . l:result['detail']
        endif
        call add(l:words, l:word)
    endfor
    call complete(col('.') - len(l:response.old_prefix), l:words)
endfunction

function! s:outCallBack(id, data) abort
    call s:genComplete(a:data)
endfunction

function! s:handleStdout(id, data, event) abort
    call s:genComplete(a:data)
endfunction

function! s:parseCompletion(completion) abort
    let l:item = {}
    let l:item.word = a:completion.new_prefix
    if has_key(a:completion, 'kind')
        let l:item.kind = a:completion.kind
    endif
    if has_key(a:completion, 'documentation')
        let l:item.info = a:completion.documentation
    endif
    if has_key(a:completion, 'detail')
        let l:item.menu = a:completion.detail
    endif
    if has_key(a:completion, 'deprecated')
        if has_key(l:item, 'menu')
            let l:item.menu = '[deprecated] ' . l:item.menu
        else
            let l:item.menu = '[deprecated']
        endif
    endif
    return l:item
endfunction

function! s:formatRequestMessage(request) abort
    return json_encode({"version": "1.0.14", "request": a:request})
endfunction

function! s:sendCommand(message, params) abort
    if has('nvim')
        call chansend(s:getTabNineJob(), s:formatRequestMessage({a:message: a:params}))
        call chansend(s:getTabNineJob(), "\n")
    else
        call ch_sendraw(s:getTabNineJob(), s:formatRequestMessage({a:message: a:params}))
        call ch_sendraw(s:getTabNineJob(), "\n")
    endif
endfunction

function! tabnine#complete() abort
    " start
    let l:job = s:getTabNineJob()
    let l:params = s:getParamsForCompletion(100 * 1024)
    let l:params["filename"] = expand('%:p')
    call s:sendCommand("Autocomplete", l:params)
    return []
endif
endfunction
