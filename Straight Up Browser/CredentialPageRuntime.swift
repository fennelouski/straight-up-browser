import Foundation

/// A separate isolated-world runtime for human-selected logins. Unlike the
/// agent's semantic runtime, this runs in each frame and has no agent API.
nonisolated enum CredentialPageRuntime {
    static let bootstrap = #"""
    (() => {
      if (window.__browserCredentialRuntime) return;
      const token = crypto.randomUUID();
      let rememberedUsername = '', suppress = false;
      const visible = el => el && !el.disabled && !el.readOnly && el.getClientRects().length &&
        getComputedStyle(el).visibility !== 'hidden' && getComputedStyle(el).display !== 'none';
      const tokens = el => String(el.autocomplete || '').toLowerCase().split(/\s+/);
      const usernameLike = el => ['text','email','tel'].includes(el.type) &&
        (tokens(el).includes('username') || /^(account_name(?:_text_field)?|apple-?id|username|login|email)$/i.test(el.id || '') ||
         /^(username|login|email)$/i.test(el.name || ''));
      const fields = (root = document, allowNew = false) => {
        const inputs = Array.from(root.querySelectorAll('input'));
        const password = inputs.find(el => el.type === 'password' && (allowNew || !tokens(el).includes('new-password')) && visible(el));
        const scope = password?.form ? Array.from(password.form.querySelectorAll('input')) : inputs;
        const username = scope.find(el => usernameLike(el) && visible(el)) ||
          (password && scope.slice(0, scope.indexOf(password)).reverse().find(el =>
            ['text','email','tel'].includes(el.type) && visible(el)));
        return {username, password};
      };
      const post = body => {
        try { window.webkit.messageHandlers.straightUpSemantic.postMessage({
          ...body, documentToken: token, origin: location.origin
        }); } catch (_) {}
      };
      const report = () => {
        if (suppress) return;
        const el = document.activeElement, pair = fields();
        if (!visible(el) || (el !== pair.username && el !== pair.password)) return;
        const r = el.getBoundingClientRect();
        post({type: 'loginFieldFocused', rect: {x:r.x,y:r.y,width:r.width,height:r.height}});
      };
      document.addEventListener('focusin', () => {
        let remaining = 20;
        const tick = () => { report(); if (--remaining > 0) requestAnimationFrame(tick); };
        tick();
      }, true);
      window.addEventListener('scroll', report, {capture:true,passive:true});
      window.addEventListener('resize', report);
      document.addEventListener('focusout', () => {
        if (!suppress) post({type:'loginFieldDismissed'});
      }, true);
      // Apple and other SPA sign-ins replace the username form with a password
      // form and often handle a button click without dispatching submit.
      const capture = root => {
        const pair = fields(root, true);
        if (!pair.username && !pair.password) return;
        const all = Array.from(root.querySelectorAll('input'));
        const user = pair.username || all.find(el => usernameLike(el) && el.value);
        if (user?.value) rememberedUsername = user.value;
        if (!rememberedUsername && !pair.password) return;
        const body = {type:'loginSubmitted',username:rememberedUsername};
        if (pair.password?.value) body.password = pair.password.value;
        post(body);
      };
      document.addEventListener('submit', event => {
        if (event.target instanceof HTMLFormElement) capture(event.target);
      }, true);
      document.addEventListener('click', event => {
        if (!event.isTrusted) return;
        const button = event.target.closest('button,input[type=submit],[role=button]');
        if (!button) return;
        const label = String(button.innerText || button.value || button.getAttribute('aria-label') || '').trim();
        if (button.type === 'submit' || /^(sign in|log in|continue|next|submit)$/i.test(label)) capture(button.form || button.closest('form') || document);
      }, true);
      document.addEventListener('keydown', event => {
        if (!event.isTrusted || event.key !== 'Enter') return;
        const pair = fields(document, true), el = document.activeElement;
        if (el === pair.username || el === pair.password) capture(el.form || document);
      }, true);
      const setValue = (el,value) => {
        const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set;
        setter.call(el,value);
        el.dispatchEvent(new Event('input',{bubbles:true}));
        el.dispatchEvent(new Event('change',{bubbles:true}));
      };
      Object.defineProperty(window,'__browserCredentialRuntime',{value:{
        isCredentialField(el) { const pair=fields(); return el === pair.username || el === pair.password; },
        apply(request) {
          if (request.documentToken && request.documentToken !== token) return {filled:false};
          if (request.origin !== location.origin) return {filled:false};
          const pair = fields();
          if (!pair.username && !pair.password) return {filled:false};
          suppress = true;
          try {
            if (pair.username) { setValue(pair.username,request.username); rememberedUsername=request.username; }
            if (pair.password) setValue(pair.password,request.password);
            if (request.submit) {
              const field = pair.password || pair.username;
              const form = field.form;
              const button = Array.from((form || document).querySelectorAll('button,input[type=submit],[role=button]'))
                .find(el => visible(el) && (el.type === 'submit' || /^(sign in|log in|continue|next)$/i.test(String(el.innerText || el.value || el.getAttribute('aria-label') || '').trim())));
              if (button) button.click();
              else if (form?.requestSubmit) form.requestSubmit();
            }
            return {filled:true,usernameFilled:!!pair.username,passwordFilled:!!pair.password};
          } finally { suppress=false; }
        }
      }});
    })();
    """#

    static let apply = #"""
    return window.__browserCredentialRuntime?.apply(request) || {filled:false};
    """#
}
