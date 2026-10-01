document.querySelectorAll(".copy").forEach((button) => {
    const label = button.textContent;
    button.addEventListener("click", async () => {
        const code = button.parentElement.querySelector("code");
        try {
            await navigator.clipboard.writeText(code.textContent.trim());
            button.textContent = button.dataset.done;
            button.classList.add("done");
        } catch {
            const range = document.createRange();
            range.selectNodeContents(code);
            const selection = window.getSelection();
            selection.removeAllRanges();
            selection.addRange(range);
        }
        setTimeout(() => {
            button.textContent = label;
            button.classList.remove("done");
        }, 1600);
    });
});
