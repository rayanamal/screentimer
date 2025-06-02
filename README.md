Screen Time features for NixOS.

The goal of this project is to turn your general-purpose computing device into a narrow-purpose computing device, a purpose that aligns with your own goals, in order to prevent distractions and maximize productivity. It works extremely well on myself (I have ADHD), your mileage may vary.

It's not a proper Nix package, just some configuration options along with a script.

## Features

- Downtime: Block usage of your computer outside of specified working hours.
- URL Allowlist: Allow only specified domains in your browser.

## Requirements

### 1. Not knowing root password

In order for this system to work properly, you should not know what your root password is. Unfortunately on Linux, a lot of stuff depend on having root access. Fortunately, the stuff you need root access for is *rarely* an emergency. You might be hesitant to make the step, but hey, I'm living just fine without immediate sudo access.

In order to not know root password, and yet still be able to be root and do system modifications when a need arises, here's what you need to do:

1. [Timelock](https://github.com/rayanamal/timelock) your root password. Set the decryption time to an amount that'll prevent impulsive behavior. Whenever you want to make a change in your system, you can start decrypting the password. After the decryption is complete, you can do whatever system modifications you want, and then delete back the decrypted password. For most people, 1-6 hours is enough.

    I personally note down system modifications which require root access and do all of them at once every few weeks.

2. Remove your user from the sudo group.
<pre><code>users.users.&lt;name&gt;.extraGroups = [ <span style="text-decoration: line-through;">wheel</span> ]
</code></pre>

3. (*Suggestion*) If you don't know already, containers are a good solution that allow you to run any Linux distribution freely while having Screen Time restrictions active on the host. Some rootless solutions of note are [distrobox](https://distrobox.it/) and [podman](https://podman.io/).

### 2. Connectivity

The program won't trust system clock and will instead fetch clock information from google.com. If you are unable to connect to the network at system startup, the program will block the computer after 3 minutes/day. You can change this value in the configuration.

## Installation

1. As this program will be part of your NixOS configuration, it's wise to keep it somewhere under your `/etc/nixos`. Clone the repository **with sudo** to your `/etc/nixos`:
```bash
sudo git clone "https://github.com/rayanamal/screentimer.git" /etc/nixos/screentimer
```

2. Using your editor, edit the file `/etc/nixos/screentimer/config.toml` to set the configuration options. They're documented in the comments.

3. Add the systemd service to `/etc/nixos/configuration.nix`:
```nix
  systemd.services.screentimer = {
    wantedBy = [ "multi-user.target" ];
    serviceConfig.Restart = "on-failure";
    script = "/etc/nixos/screentimer/screentimer.nu";
    path = [pkgs.nushell pkgs.systemd pkgs.iputils];
  };
  
  environment.etc."screentimer/config.toml" = {
   	source = /etc/nixos/assets/screentimer/config.toml;
  };
```
If you cloned the repo elsewhere, edit the paths accordingly.

4. Add the Chromium allowlist to your `configuration.nix`. This will completely block any websites not specified here. Tailor the website list for your own browsing needs. Here is an example starter developer config.
<details>
    <summary>Example starter config</summary>

```nix
  programs.chromium = {
    enable = true;
    extensions = [
      "eimadpbcbfnmbkopoojfekhnkhdbieeh" # Dark Reader
      "ddkjiahejlhfcafbddmgiahcphecmpfh" # UBlock Origin Lite
      "inomeogfingihgjfjlpeplalcfajhgai" # Chrome Remote Desktop
    ];
    extraOpts = {
      "URLBlocklist" = [
       	"*"
      ];
      "URLAllowlist" = [
        # Google
        # It's up to you whether to allow Google search. I found it works better for me if I don't.
       	# "www.google.com/search" 
       	"photos.google.com"
        # These three are intentional, not duplicates
       	"www.google.com/maps" 
       	"google.com/maps"
       	"maps.google.com"
       	"google.com/url"
       	"gstatic.com"
       	"apps.google.com"
       	"remotedesktop.google.com"
       	"business.google.com"
       	"workspace.google.com"
       	"one.google.com"
       	"ogs.google.com"
       	"gds.google.com"
       	"drive.google.com"
       	"meet.google.com"
       	"docs.google.com"
       	"accounts.google.com"
       	"accounts.youtube.com"
       	"myaccount.google.com"
       	"support.google.com"
       	"cloud.google.com"
       	"chromeenterprise.google"
       	"chromewebstore.google.com"
       	"chrome.com"
        
        # Apple
        "apple.com"
        "icloud.com"
        "icloud-sandbox.com"
        "icloud-content.com"
        
        # To be able to open a 'simple' online shared Word document
        # No, I'm not joking. The meme is real: https://goomics.net/img/2011-06-27_organizational_charts.png
        "microsoft.com"
        "microsoft365.com"
        "live.com"
        "office365.com"
        "office.com"
        "microsoftonline.com"
        "cloud.microsoft"
        "sharepoint.com"
        "officeapps.live.com"
        "windowsazure.com"
        "aka.ms"
        "1drv.ms"
        "microsoftpersonalcontent.com"
         
        # Miscellanous
        "localhost"
        "file://*"
        "chrome://*"
        "devtools://*"
        "vscode://*"
        "mailto://*"
        "127.0.0.1"
        "page.link" # Firebase link shortener, used in many websites
         	
        # Developer Q & A forums
        "archlinux.org"
        "man7.org"
        "die.net"
        "stackexchange.com"
        "debian.org"
        "stackoverflow.com"
        "superuser.com"
        "askubuntu.com"
        "ubuntu.com"
        "freedesktop.org"
        
        # To be able to open Matrix chats
        "element://*"
        "matrix.to"
        "matrix.org" 
        
        # Github
        "github.com"
        "githubusercontent.com"
        # "github.dev" # Github codespaces
        "github.io" # Github pages
        
        # AI services
        "chatgpt.com"
        "openai.com"
        "claude.ai"
        "anthropic.com"
        "gemini.google.com"
        
        # Nix resources
        "nix.dev"
        "nixos.org"
        "nixos.wiki"
        "noogle.dev"
        
        # Payments
        "stripe.com"
        "stripecdn.com"
        
        # Entertainment
        "monkeytype.com"
        
        # Captcha services
        "arkoselabs.com"
        "octocaptcha.com"
        "hcaptcha.com"
        "cloudflare.com"
        "www.google.com/recaptcha"
        
        # Other
        "gitlab.com"
        "techlockdown.com"  # <- Check it out, if you're interested in a similar solution for your phone
      ];
    };
  };
  
  # We block Firefox altogether to prevent bypass.
  programs.firefox = {
    enable = true;
    policies.WebsiteFilter = {
      Block =  ["<all_urls>"];
    };
  };

  # Thank me later...
  networking.hosts = {
    "127.0.0.1" = [
      "news.ycombinator.com"
    ];
  };

```

</details>

## Some unsolicited suggestions on screen-timing your phone
If you want to use non-bypassable Screen Time measures found in this repo for your computer, it's possible you want to use them for your phone too. 
- The easiest way to do that (especially if you're in the US and don't use apps like WhatsApp) is to get an "alternative device", for example a [Light Phone](https://www.thelightphone.com/). 
- If you can't do that, the easiest way is probably [TechLockdown](https://techlockdown.com).
- Even if it's not a total restriction, reflection apps like _one sec_ (available on mobile & desktop) are scientifically proven to work to some significant degree by acting as friction.

## Contributing and Feedback

Let me know how this project worked (or didn't) for you!

Please let me know before making a PR.

## Some notes...

### Do infinite content feeds negatively affect otherwise healthy (neurotypical) people?

> Over the years of not using social media because I [have ADHD and] can't handle it, I arrived at the definitive conclusion that any form of social media modifies a person's worldview, life goals, personality and behavior to significant degrees. I came to call this "ungrounding", it's in effect a detachment from how they would think and act if they were exposed to only the real world and not the artificial world that doesn't even exist.

> Little people remember anymore, but a decade ago people used to remark how the personality and manner of behavior of somebody they know changed when they got their first smartphone.

> This effect doesn't skip anybody, can be caused by plain old cable TV and very little use (about 30 mins./day) is enough. When I completely cut artificial content years ago, it took about 3 months for me to feel the veil lifted from my eyes and able to see the real world as-is and not through the lens of the content I consumed. It was a profound feeling when I first realized what happened to me, and it left me thinking and pitying all others I knew who are trapped with thought patterns unmatching their reality - most otherwise good, hardworking people.

> They didn't realize the lenses being put on (because it happened so slowly) and now they don't know the world isn't quite the way they see it is. No matter whether they see it as rose-colored or black-and-white, with an optimistic hue or a pessimistic blue, because of the fake, narrow representations they get exposed to regularly.

> It's almost like a mind virus, and you know what? It's immediately recognizable to me, the glossy eyes when they start to talk about X thing and Y event and Z news that all are actually totally irrelevant for them if they'd stop to think about it, yet they for some mysterious reason they put a high importance on them and talk about it as if it's life and death. I believe anybody who drops artificial content and re-grounds with reality will be able to readily see how captive the minds of their very loved ones are.

### How did this project came to be?

I had undiagnosed ADHD until my adulthood. This project was borne out of an effort to cope with it, even though I didn't know what it was I'm coping with.

Following paraghraphs are from several years ago, from the first iterations of this project. They show rather clearly how *undiagnosed and untreated* ADHD leads one to have incorrect beliefs about how healthy and normal people's brains work.

> It's known that Big Tech companies are specifically targeting and engineering for your attention, optimizing for dopamine hits to keep the ad dollars flowing. Hundreds of millions are spent per year to A/B test some UI change, will it lead to more "engagement" or not? So it's not fair at all to put the blame on the user. When you unleash algorithmic feeds on a 21th century population, inevitably a sizeable fraction gets caught in the net.

> For many people, there is no need for Screen Time. They're busy enough with their daily lives. For others, a little bit of friction (think about iOS Screen Time without a password) is enough. Yet our kind, software engineers, are ironically the ones most prone to falling to bad usage habits, due to our fascination with technology, the lack of friction because of our tech-savviness, and the chronically online nature of our job. Thus the need for Screen Time controls, and the need for this project. I'm a happy user since 2 years now, and I see the positive effect on myself.

While there's truth in what I wrote, it's easy to see that I was (falsely) thinking other people have as little capacity to focus and as much tendency to get distracted as I did.

## Future directions

- We can rebuild NixOS with some delay (6 hours?) and impulse control will work without the user ever needing to unlock root access. Cons: No iterative feedback loop.
  - We can have time periods in which a directory is watched and system being auto-rebuilt on every change?
- We can create a microcontroller-based device for entering passwords by acting as a Bluetooth/USB keyboard.
  - The device can set and store the BIOS password. This would allow us to trust the system clock without any need for connectivity. 
  - Such a device can further be developed into a unified interface for holding the Screen Time PINs, root account passwords, etc. of all kinds of devices including smartphones. 
  - It could present a UI over Wi-Fi, e.g. on your smartphone. 
  - It could enable self-hosting the commitment device (timelock) in a non-compute-intensive manner by acting as a password vault with time rules. This would not require a timelock. External back-ups of these passwords can be kept in their timelocked form. 
  - This device could also double as a hardware key (i.e. Yubikey). 